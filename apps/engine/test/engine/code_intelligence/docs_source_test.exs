defmodule Engine.CodeIntelligence.DocsSourceTest do
  use ExUnit.Case, async: false

  alias Engine.CodeIntelligence.Docs
  alias Engine.Dispatch
  alias Engine.Search.Store
  alias Engine.Search.Store.Backends.Ets
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry
  alias Forge.Test.EventualAssertions
  alias Forge.Test.Fixtures

  import EventualAssertions

  @moduletag :monorepo

  # __DIR__ is apps/engine/test/engine/code_intelligence
  # We need to go to apps/forge/test/fixtures/monorepo
  @backend_source_path Path.expand("../../../../forge/test/fixtures/monorepo/backend/lib/backend.ex", __DIR__)
  @backend_user_source_path Path.expand("../../../../forge/test/fixtures/monorepo/backend/lib/backend/user.ex", __DIR__)

  describe "docs_from_source" do
    setup do
      project = Fixtures.project(:monorepo)
      Engine.set_project(project)

      start_supervised!(Dispatch)
      start_supervised!(Ets)
      start_supervised!({Store, [project, &noop_create/1, &noop_update/2, Ets]})

      assert_eventually alive?()
      Store.enable()
      assert_eventually ready?(), 1500

      # Populate the search index with our test entries
      Store.replace([
        %Entry{
          id: 1,
          subject: "Backend",
          type: :module,
          subtype: :definition,
          path: @backend_source_path,
          range: %Range{
            start: %Position{line: 1, character: 1},
            end: %Position{line: 28, character: 4}
          }
        },
        %Entry{
          id: 2,
          subject: "Backend.User",
          type: :module,
          subtype: :definition,
          path: @backend_user_source_path,
          range: %Range{
            start: %Position{line: 1, character: 1},
            end: %Position{line: 22, character: 4}
          }
        }
      ])

      {:ok, project: project}
    end

    test "extracts documentation from source for uncompiled module" do
      # Backend module is not compiled, but source exists in the monorepo fixture
      result = Docs.for_module(Backend, [])

      assert {:ok, docs} = result
      assert docs.module == Backend
      assert is_binary(docs.doc)
      assert docs.doc =~ "The main Backend module"
    end

    test "extracts function documentation from source" do
      {:ok, docs} = Docs.for_module(Backend, [])

      assert %{add: entries} = docs.functions_and_macros
      assert [entry | _] = entries
      assert entry.name == :add
      assert entry.arity == 2
      assert is_binary(entry.doc)
      assert entry.doc =~ "Adds two numbers"
    end

    test "extracts type documentation for struct module" do
      {:ok, docs} = Docs.for_module(Backend.User, [])

      assert docs.module == Backend.User
      assert docs.doc =~ "User management module"
    end
  end

  defp noop_create(_project), do: {:ok, []}
  defp noop_update(_project, _entries), do: {:ok, [], []}

  defp ready? do
    alive?() and Store.loaded?()
  end

  defp alive? do
    case Process.whereis(Store) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
