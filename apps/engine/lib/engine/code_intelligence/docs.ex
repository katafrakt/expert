defmodule Engine.CodeIntelligence.Docs do
  alias ElixirSense.Core.Parser
  alias ElixirSense.Core.State.ModFunInfo
  alias Engine.Modules
  alias Engine.Search.Store
  alias Forge.CodeIntelligence.Docs
  alias Forge.CodeIntelligence.Docs.Entry
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry, as: SearchEntry

  require Logger

  @moduledoc """
  Utilities for fetching documentation for a compiled module.
  """

  @doc """
  Fetches known documentation for the given module.

  When the module's BEAM file is not available (e.g., for uncompiled projects
  in monorepo subdirectories), falls back to extracting documentation from
  source code using the search index.

  ## Options

    * `:exclude_hidden` - if `true`, returns `{:error, :hidden}` for
      modules that have been marked as hidden using `@moduledoc false`.
      Defaults to `false`.

  """
  @spec for_module(module(), [opt]) :: {:ok, Docs.t()} | {:error, any()}
        when opt: {:exclude_hidden, boolean()}
  def for_module(module, opts) when is_atom(module) do
    exclude_hidden? = Keyword.get(opts, :exclude_hidden, false)

    with {:ok, beam} <- Modules.ensure_beam(module),
         {:ok, docs} <- parse_docs(module, beam) do
      if docs.doc == :hidden and exclude_hidden? do
        {:error, :hidden}
      else
        {:ok, docs}
      end
    else
      {:error, reason} when reason in [:not_found, :nofile, :unavailable] ->
        docs_from_source(module, exclude_hidden?)

      other ->
        other
    end
  end

  defp parse_docs(module, beam) do
    case Modules.fetch_docs(beam) do
      {:ok, {:docs_v1, _anno, _lang, _format, module_doc, _meta, entries}} ->
        entries_by_kind = Enum.group_by(entries, &doc_kind/1)
        function_entries = Map.get(entries_by_kind, :function, [])
        macro_entries = Map.get(entries_by_kind, :macro, [])
        callback_entries = Map.get(entries_by_kind, :callback, [])
        type_entries = Map.get(entries_by_kind, :type, [])

        spec_defs = beam |> Modules.fetch_specs() |> ok_or([])
        callback_defs = beam |> Modules.fetch_callbacks() |> ok_or([])
        type_defs = beam |> Modules.fetch_types() |> ok_or([])

        result = %Docs{
          module: module,
          doc: Entry.parse_doc(module_doc),
          functions_and_macros:
            parse_entries(module, function_entries ++ macro_entries, spec_defs),
          callbacks: parse_entries(module, callback_entries, callback_defs),
          types: parse_entries(module, type_entries, type_defs)
        }

        {:ok, result}

      _ ->
        {:error, :no_docs}
    end
  end

  defp doc_kind({{kind, _name, _arity}, _anno, _sig, _doc, _meta}) do
    kind
  end

  defp parse_entries(module, raw_entries, defs) do
    defs_by_name_arity =
      Enum.group_by(
        defs,
        fn {name, arity, _formatted, _quoted} -> {name, arity} end,
        fn {_name, _arity, formatted, _quoted} -> formatted end
      )

    raw_entries
    |> Enum.map(fn raw_entry ->
      entry = Entry.from_docs_v1(module, raw_entry)
      defs = Map.get(defs_by_name_arity, {entry.name, entry.arity}, [])
      %Entry{entry | defs: defs}
    end)
    |> Enum.group_by(& &1.name)
  end

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or(_, default), do: default

  # Source-based docs extraction for uncompiled modules (e.g., monorepo subdirectories)

  defp docs_from_source(module, exclude_hidden?) do
    module_subject = Formats.module(module)

    with {:ok, [%SearchEntry{path: path} | _]} <-
           Store.exact(module_subject, type: :module, subtype: :definition),
         {:ok, source} <- File.read(path) do
      metadata = Parser.parse_string(source, true, false, nil)

      case extract_module_doc(metadata, module) do
        {:ok, module_doc} ->
          docs = %Docs{
            module: module,
            doc: module_doc,
            functions_and_macros: extract_functions_from_source(metadata, module),
            callbacks: %{},
            types: extract_types_from_source(metadata, module)
          }

          if docs.doc == :hidden and exclude_hidden? do
            {:error, :hidden}
          else
            {:ok, docs}
          end

        :error ->
          {:error, :no_doc}
      end
    else
      _ -> {:error, :no_doc}
    end
  end

  defp extract_module_doc(metadata, module) do
    case Map.get(metadata.mods_funs_to_positions, {module, nil, nil}) do
      %ModFunInfo{doc: doc} ->
        {:ok, parse_source_doc(doc)}

      _ ->
        :error
    end
  end

  defp extract_functions_from_source(metadata, module) do
    specs_by_name_arity = extract_specs_by_name_arity(metadata, module)

    metadata.mods_funs_to_positions
    |> Enum.filter(fn
      {{^module, fun, arity}, %ModFunInfo{type: type}} when not is_nil(fun) and not is_nil(arity) ->
        type in [:def, :defmacro, :defdelegate, :defguard]

      _ ->
        false
    end)
    |> Enum.map(fn {{^module, fun, arity}, %ModFunInfo{} = fun_info} ->
      kind = ModFunInfo.get_category(fun_info)
      params = fun_info.params |> List.last() || []
      signature = format_signature(fun, params)
      spec_defs = Map.get(specs_by_name_arity, {fun, arity}, [])

      %Entry{
        module: module,
        name: fun,
        arity: arity,
        kind: kind,
        doc: parse_source_doc(fun_info.doc),
        signature: [signature],
        defs: spec_defs,
        metadata: Map.take(fun_info.meta, [:defaults, :since, :guard, :deprecated])
      }
    end)
    |> Enum.group_by(& &1.name)
  end

  defp extract_types_from_source(metadata, module) do
    metadata.types
    |> Enum.filter(fn
      {{^module, _type, _arity}, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {{^module, type, arity}, type_info} ->
      spec_def =
        type_info.specs
        |> List.wrap()
        |> List.last()

      %Entry{
        module: module,
        name: type,
        arity: arity,
        kind: :type,
        doc: parse_source_doc(type_info.doc),
        signature: [],
        defs: List.wrap(spec_def),
        metadata: Map.take(type_info.meta || %{}, [:opaque, :since, :deprecated])
      }
    end)
    |> Enum.group_by(& &1.name)
  end

  defp extract_specs_by_name_arity(metadata, module) do
    metadata.specs
    |> Enum.filter(fn
      {{^module, _fun, _arity}, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {{^module, fun, arity}, spec_info} ->
      formatted_specs =
        spec_info.specs
        |> Enum.reverse()
        |> Enum.filter(&String.starts_with?(&1, "@spec"))
        |> Enum.map(&String.replace_prefix(&1, "@spec ", ""))

      {{fun, arity}, formatted_specs}
    end)
    |> Map.new()
  end

  defp format_signature(fun, params) do
    args =
      params
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn
        {{:\\, _, [name, _default]}, _idx} -> Macro.to_string(name)
        {name, _idx} when is_atom(name) -> Atom.to_string(name)
        {{name, _, _}, _idx} when is_atom(name) -> Atom.to_string(name)
        {_, idx} -> "arg#{idx}"
      end)

    "#{fun}(#{args})"
  end

  defp parse_source_doc(""), do: :none
  defp parse_source_doc(nil), do: :none
  defp parse_source_doc(false), do: :hidden
  defp parse_source_doc(doc) when is_binary(doc), do: doc
  defp parse_source_doc(_), do: :none
end
