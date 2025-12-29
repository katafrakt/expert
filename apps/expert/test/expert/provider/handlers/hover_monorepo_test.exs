defmodule Expert.Provider.Handlers.HoverMonorepoTest do
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.EngineApi.Messages
  alias Forge.Project
  alias Forge.Test.Fixtures
  alias GenLSP.Requests
  alias GenLSP.Structures

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport

  require Messages

  use ExUnit.Case, async: false

  @moduletag :monorepo

  describe "hover in monorepo with subdirectory project" do
    setup do
      project = Fixtures.project(:monorepo)

      start_supervised!({Forge.NodePortMapper, []})
      start_supervised!(Expert.Application.document_store_child_spec())
      start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
      start_supervised!({Expert.Project.Supervisor, project})

      :ok = EngineApi.register_listener(project, self(), [Messages.project_compiled()])

      receive do
        Messages.project_compiled() -> :ok
      after
        5000 -> :ok
      end

      {:ok, project: project}
    end

    test "documentation for module in subdirectory project", %{project: project} do
      content = ~q[
        defmodule MyModule do
          alias Backend

          def call_backend do
            |Backend.hello()
          end
        end
      ]

      {position, content} = pop_cursor(content)
      {:ok, document} = document_in_subdirectory(project, "backend/lib/test_file.ex", content)

      {:ok, request} = hover_request(document.uri, position)
      config = Expert.Configuration.new(project: project)

      result = Handlers.Hover.handle(request, config)

      assert {:ok, %Structures.Hover{} = hover} = result
      assert hover.contents.kind == "markdown"
      assert hover.contents.value =~ "The main Backend module"
    end

    test "documentation for function in subdirectory project", %{project: project} do
      content = ~q[
        defmodule MyModule do
          def use_backend do
            Backend.|add(1, 2)
          end
        end
      ]

      {position, content} = pop_cursor(content)
      {:ok, document} = document_in_subdirectory(project, "backend/lib/test_file.ex", content)

      {:ok, request} = hover_request(document.uri, position)
      config = Expert.Configuration.new(project: project)

      result = Handlers.Hover.handle(request, config)

      assert {:ok, %Structures.Hover{} = hover} = result
      assert hover.contents.value =~ "Adds two numbers together"
    end

    test "documentation for struct in subdirectory project", %{project: project} do
      content = ~q[
        defmodule MyModule do
          def create_user do
            %Backend.|User{id: 1, name: "Test", email: "test@example.com"}
          end
        end
      ]

      {position, content} = pop_cursor(content)
      {:ok, document} = document_in_subdirectory(project, "backend/lib/test_file.ex", content)

      {:ok, request} = hover_request(document.uri, position)
      config = Expert.Configuration.new(project: project)

      result = Handlers.Hover.handle(request, config)

      assert {:ok, %Structures.Hover{} = hover} = result
      assert hover.contents.value =~ "User management module"
    end
  end

  defp document_in_subdirectory(project, relative_path, content) do
    uri =
      project
      |> Project.project_path()
      |> Path.join(relative_path)
      |> Document.Path.ensure_uri()

    uri
    |> Document.Path.from_uri()
    |> Path.dirname()
    |> File.mkdir_p!()

    case Document.Store.open(uri, content, 1) do
      :ok ->
        Document.Store.fetch(uri)

      {:error, :already_open} ->
        Document.Store.close(uri)
        document_in_subdirectory(project, relative_path, content)

      error ->
        error
    end
  end

  defp hover_request(path, %Position{} = position) do
    hover_request(path, position.line, position.character)
  end

  defp hover_request(path, line, char) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri) do
      req = %Requests.TextDocumentHover{
        id: Expert.Protocol.Id.next(),
        params: %Structures.HoverParams{
          # convert line and char to zero-based
          position: %Structures.Position{line: line - 1, character: char - 1},
          text_document: %Structures.TextDocumentIdentifier{uri: uri}
        }
      }

      Convert.to_native(req)
    end
  end
end
