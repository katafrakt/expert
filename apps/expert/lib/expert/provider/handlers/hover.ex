defmodule Expert.Provider.Handlers.Hover do
  @moduledoc """
  Handles textDocument/hover LSP requests.

  This handler attempts to provide hover documentation using two strategies:
  1. Primary: Use the Engine's compiled module documentation (EngineApi.docs)
  2. Fallback: Use ElixirSense's source-based documentation extraction

  The fallback is important for monorepo scenarios where the Engine may not have
  compiled modules from subdirectory projects.
  """

  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Provider.Markdown
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.CodeIntelligence.Docs
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Project
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  def handle(
        %Requests.TextDocumentHover{
          params: %Structures.HoverParams{} = params
        },
        %Configuration{} = config
      ) do
    document = Document.Container.context_document(params, nil)

    maybe_hover =
      with {:ok, _document, %Ast.Analysis{} = analysis} <-
             Document.Store.fetch(document.uri, :analysis),
           {:ok, entity, range} <- resolve_entity(config.project, analysis, params.position),
           {:ok, markdown} <- hover_content(entity, config.project) do
        content = Markdown.to_content(markdown)
        %Structures.Hover{contents: content, range: range}
      else
        error ->
          # Primary hover failed - try source-based fallback
          Logger.debug("Primary hover failed: #{inspect(error)}, trying source-based fallback")

          # Re-resolve entity and try source-based extraction
          with {:ok, _document, %Ast.Analysis{} = analysis} <-
                 Document.Store.fetch(document.uri, :analysis),
               {:ok, entity, range} <- resolve_entity(config.project, analysis, params.position),
               %Structures.Hover{} = hover <- source_based_hover(entity, range, config.project) do
            hover
          else
            _ ->
              # Last resort: try ElixirSense on current document
              elixir_sense_fallback(document, params.position)
          end
      end

    {:ok, maybe_hover}
  end

  defp resolve_entity(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
    EngineApi.resolve_entity(project, analysis, position)
  end

  defp hover_content({kind, module}, %Project{} = project) when kind in [:module, :struct] do
    case EngineApi.docs(project, module, exclude_hidden: false) do
      {:ok, %Docs{} = module_docs} ->
        header = module_header(kind, module_docs)
        types = module_header_types(kind, module_docs)

        additional_sections = [
          module_doc(module_docs.doc),
          module_footer(kind, module_docs)
        ]

        if Enum.all?([types | additional_sections], &empty?/1) do
          {:error, :no_doc}
        else
          header_block = "#{header}\n\n#{types}" |> String.trim() |> Markdown.code_block()
          {:ok, Markdown.join_sections([header_block | additional_sections])}
        end

      _ ->
        {:error, :no_doc}
    end
  end

  defp hover_content({:call, module, fun, arity}, %Project{} = project) do
    with {:ok, %Docs{} = module_docs} <- EngineApi.docs(project, module),
         {:ok, entries} <- Map.fetch(module_docs.functions_and_macros, fun) do
      sections =
        entries
        |> Enum.sort_by(& &1.arity)
        |> Enum.filter(&(&1.arity >= arity))
        |> Enum.map(&entry_content/1)

      {:ok, Markdown.join_sections(sections, Markdown.separator())}
    end
  end

  defp hover_content({:type, module, type, arity}, %Project{} = project) do
    with {:ok, %Docs{} = module_docs} <- EngineApi.docs(project, module),
         {:ok, entries} <- Map.fetch(module_docs.types, type) do
      case Enum.find(entries, &(&1.arity == arity)) do
        %Docs.Entry{} = entry ->
          {:ok, entry_content(entry)}

        _ ->
          {:error, :no_type}
      end
    end
  end

  defp hover_content(type, _) do
    {:error, {:unsupported, type}}
  end

  defp module_header(:module, %Docs{module: module}) do
    Ast.Module.name(module)
  end

  defp module_header(:struct, %Docs{module: module}) do
    "%#{Ast.Module.name(module)}{}"
  end

  defp module_header_types(:module, %Docs{}), do: ""

  defp module_header_types(:struct, %Docs{} = docs) do
    docs.types
    |> Map.get(:t, [])
    |> sort_entries()
    |> Enum.flat_map(& &1.defs)
    |> Enum.join("\n\n")
  end

  defp module_doc(s) when is_binary(s), do: s
  defp module_doc(_), do: nil

  defp module_footer(:module, docs) do
    callbacks = format_callbacks(docs.callbacks)

    unless empty?(callbacks) do
      Markdown.section(callbacks, header: "Callbacks")
    end
  end

  defp module_footer(:struct, _docs), do: nil

  defp entry_content(%Docs.Entry{kind: fn_or_macro} = entry)
       when fn_or_macro in [:function, :macro] do
    call_header = call_header(entry)
    specs = Enum.map_join(entry.defs, "\n", &("@spec " <> &1))

    header =
      [call_header, specs]
      |> Markdown.join_sections()
      |> String.trim()
      |> Markdown.code_block()

    Markdown.join_sections([header, entry_doc_content(entry.doc)])
  end

  defp entry_content(%Docs.Entry{kind: :type} = entry) do
    header =
      Markdown.code_block("""
      #{call_header(entry)}

      #{type_defs(entry)}\
      """)

    Markdown.join_sections([header, entry_doc_content(entry.doc)])
  end

  @one_line_header_cutoff 50

  defp call_header(%Docs.Entry{kind: :type} = entry) do
    module_name = Ast.Module.name(entry.module)

    one_line_header = "#{module_name}.#{entry.name}/#{entry.arity}"

    two_line_header =
      "#{last_module_name(module_name)}.#{entry.name}/#{entry.arity}\n#{module_name}"

    if String.length(one_line_header) >= @one_line_header_cutoff do
      two_line_header
    else
      one_line_header
    end
  end

  defp call_header(%Docs.Entry{kind: maybe_macro} = entry) do
    [signature | _] = entry.signature
    module_name = Ast.Module.name(entry.module)

    macro_prefix =
      if maybe_macro == :macro do
        "(macro) "
      else
        ""
      end

    one_line_header = "#{macro_prefix}#{module_name}.#{signature}"

    two_line_header =
      "#{macro_prefix}#{last_module_name(module_name)}.#{signature}\n#{module_name}"

    if String.length(one_line_header) >= @one_line_header_cutoff do
      two_line_header
    else
      one_line_header
    end
  end

  defp last_module_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
  end

  defp type_defs(%Docs.Entry{metadata: %{opaque: true}} = entry) do
    Enum.map_join(entry.defs, "\n", fn def ->
      def
      |> String.split("::", parts: 2)
      |> List.first()
      |> String.trim()
    end)
  end

  defp type_defs(%Docs.Entry{} = entry) do
    Enum.join(entry.defs, "\n")
  end

  defp format_callbacks(callbacks) do
    callbacks
    |> Map.values()
    |> List.flatten()
    |> sort_entries()
    |> Enum.map_join("\n", fn %Docs.Entry{} = entry ->
      header =
        entry.defs
        |> Enum.map_join("\n", &("@callback " <> &1))
        |> Markdown.code_block()

      if is_binary(entry.doc) do
        """
        #{header}
        #{entry_doc_content(entry.doc)}
        """
      else
        header
      end
    end)
  end

  defp entry_doc_content(s) when is_binary(s), do: String.trim(s)
  defp entry_doc_content(_), do: nil

  defp sort_entries(entries) do
    Enum.sort_by(entries, &{&1.name, &1.arity})
  end

  defp empty?(empty) when empty in [nil, "", []], do: true
  defp empty?(_), do: false

  # Source-based hover extraction for when Engine-based docs aren't available.
  # This is used in monorepo scenarios where modules in subdirectory projects
  # aren't compiled by the Engine. It finds the source file and extracts docs from it.
  defp source_based_hover({kind, module}, range, %Project{} = project) when kind in [:module, :struct] do
    with {:ok, source_path} <- find_module_source(module, project),
         {:ok, source} <- File.read(source_path),
         {:ok, docs} <- extract_module_docs_from_source(source, module) do
      header = if kind == :struct, do: "%#{Ast.Module.name(module)}{}", else: Ast.Module.name(module)
      header_block = Markdown.code_block(header)
      markdown = Markdown.join_sections([header_block, docs])
      content = Markdown.to_content(markdown)
      %Structures.Hover{contents: content, range: range}
    else
      _ -> nil
    end
  end

  defp source_based_hover({:call, module, fun, arity}, range, %Project{} = project) do
    with {:ok, source_path} <- find_module_source(module, project),
         {:ok, source} <- File.read(source_path),
         {:ok, docs} <- extract_function_docs_from_source(source, module, fun, arity) do
      content = Markdown.to_content(docs)
      %Structures.Hover{contents: content, range: range}
    else
      _ -> nil
    end
  end

  defp source_based_hover({:type, module, type, arity}, range, %Project{} = project) do
    with {:ok, source_path} <- find_module_source(module, project),
         {:ok, source} <- File.read(source_path),
         {:ok, docs} <- extract_type_docs_from_source(source, module, type, arity) do
      content = Markdown.to_content(docs)
      %Structures.Hover{contents: content, range: range}
    else
      _ -> nil
    end
  end

  defp source_based_hover(_, _, _), do: nil

  # Find the source file for a module by searching the project directory
  defp find_module_source(module, %Project{} = project) do
    module_name = Ast.Module.name(module)
    # Convert Module.Name to module/name.ex or module_name.ex patterns
    possible_paths = module_to_possible_paths(module_name)

    project_root = Project.root_path(project)

    # Search for the module definition in lib directories
    result =
      Path.wildcard(Path.join([project_root, "**", "lib", "**", "*.ex"]))
      |> Enum.find(fn path ->
        basename = Path.basename(path, ".ex")
        Enum.any?(possible_paths, &(&1 == basename)) and file_defines_module?(path, module)
      end)

    case result do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp module_to_possible_paths(module_name) do
    # "Backend.User" -> ["user", "backend_user", "backend/user"]
    parts = String.split(module_name, ".")

    [
      # Last part lowercased: "User" -> "user"
      parts |> List.last() |> Macro.underscore(),
      # Full path underscored: "Backend.User" -> "backend_user"
      module_name |> Macro.underscore() |> String.replace("/", "_"),
      # Just the module name for single-part modules
      module_name |> Macro.underscore()
    ]
    |> Enum.uniq()
  end

  defp file_defines_module?(path, module) do
    case File.read(path) do
      {:ok, content} ->
        module_name = Ast.Module.name(module)
        String.contains?(content, "defmodule #{module_name}")

      _ ->
        false
    end
  end

  defp extract_module_docs_from_source(source, module) do
    # Use ElixirSense to extract docs from the source where module is defined
    # Find the line where defmodule starts
    module_name = Ast.Module.name(module)

    case find_defmodule_position(source, module_name) do
      {:ok, line, col} ->
        case ElixirSense.docs(source, line, col + 10) do
          %{docs: [%{kind: :module, docs: docs} | _]} when is_binary(docs) and docs != "" ->
            {:ok, docs}

          _ ->
            {:error, :no_docs}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp extract_function_docs_from_source(source, module, fun, _arity) do
    module_name = Ast.Module.name(module)

    # Find function definition and get docs
    case find_function_position(source, module_name, fun) do
      {:ok, line, col} ->
        case ElixirSense.docs(source, line, col) do
          %{docs: [%{kind: kind} = doc | _]} when kind in [:function, :macro] ->
            format_elixir_sense_doc(doc)

          _ ->
            {:error, :no_docs}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp extract_type_docs_from_source(source, _module, type, arity) do
    # For types, try to find @type definition
    case ElixirSense.docs(source, 1, 1) do
      %{docs: docs} ->
        case Enum.find(docs, &match?(%{kind: :type, type: ^type, arity: ^arity}, &1)) do
          %{} = doc -> format_elixir_sense_doc(doc)
          _ -> {:error, :no_docs}
        end

      _ ->
        {:error, :no_docs}
    end
  end

  defp find_defmodule_position(source, module_name) do
    lines = String.split(source, "\n")

    result =
      lines
      |> Enum.with_index(1)
      |> Enum.find_value(fn {line, line_num} ->
        case Regex.run(~r/defmodule\s+#{Regex.escape(module_name)}\b/, line, return: :index) do
          [{col, _}] -> {:ok, line_num, col + 1}
          _ -> nil
        end
      end)

    result || {:error, :not_found}
  end

  defp find_function_position(source, _module_name, fun) do
    lines = String.split(source, "\n")
    fun_str = Atom.to_string(fun)

    result =
      lines
      |> Enum.with_index(1)
      |> Enum.find_value(fn {line, line_num} ->
        # Match def/defp/defmacro followed by the function name
        # Position cursor on the function name, not the keyword
        pattern = ~r/\b(def|defp|defmacro|defmacrop)\s+(#{Regex.escape(fun_str)})\b/

        case Regex.run(pattern, line, return: :index) do
          [_, _, {fun_col, _}] -> {:ok, line_num, fun_col + 1}
          _ -> nil
        end
      end)

    result || {:error, :not_found}
  end

  # ElixirSense fallback for when the primary Engine-based hover fails.
  # This is particularly useful in monorepo scenarios where modules in
  # subdirectory projects may not be compiled by the Engine.
  defp elixir_sense_fallback(%Document{} = document, %Position{} = position) do
    source = Document.to_string(document)

    case ElixirSense.docs(source, position.line, position.character) do
      %{docs: [doc | _], range: range} ->
        case format_elixir_sense_doc(doc) do
          {:ok, markdown} ->
            content = Markdown.to_content(markdown)
            lsp_range = elixir_sense_range_to_lsp(range, document)
            %Structures.Hover{contents: content, range: lsp_range}

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  defp format_elixir_sense_doc(%{kind: :module, module: module, docs: docs}) do
    module_name = Ast.Module.name(module)
    header = Markdown.code_block(module_name)

    if empty?(docs) do
      :error
    else
      {:ok, Markdown.join_sections([header, docs])}
    end
  end

  defp format_elixir_sense_doc(%{kind: kind, module: module, function: function, args: args, specs: specs, docs: docs})
       when kind in [:function, :macro] do
    module_name = Ast.Module.name(module)
    args_str = Enum.join(args, ", ")

    macro_prefix = if kind == :macro, do: "(macro) ", else: ""
    signature = "#{macro_prefix}#{module_name}.#{function}(#{args_str})"

    specs_str =
      specs
      |> Enum.map_join("\n", &("@spec " <> &1))

    header =
      [signature, specs_str]
      |> Markdown.join_sections()
      |> String.trim()
      |> Markdown.code_block()

    {:ok, Markdown.join_sections([header, docs])}
  end

  defp format_elixir_sense_doc(%{kind: :type, module: module, type: type, arity: arity, spec: spec, docs: docs}) do
    module_name = if module, do: Ast.Module.name(module), else: nil

    header_text =
      if module_name do
        "#{module_name}.#{type}/#{arity}\n\n#{spec}"
      else
        "#{type}/#{arity}\n\n#{spec}"
      end

    header = Markdown.code_block(header_text)
    {:ok, Markdown.join_sections([header, docs])}
  end

  defp format_elixir_sense_doc(%{kind: :variable}) do
    # Variables don't have documentation
    :error
  end

  defp format_elixir_sense_doc(%{kind: :attribute, docs: docs}) when not is_nil(docs) do
    {:ok, docs}
  end

  defp format_elixir_sense_doc(_) do
    :error
  end

  defp elixir_sense_range_to_lsp(%{begin: {begin_line, begin_col}, end: {end_line, end_col}}, _document) do
    %Structures.Range{
      start: %Structures.Position{
        line: begin_line - 1,
        character: begin_col - 1
      },
      end: %Structures.Position{
        line: end_line - 1,
        character: end_col - 1
      }
    }
  end

  defp elixir_sense_range_to_lsp(_, _), do: nil
end
