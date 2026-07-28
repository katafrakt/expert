defmodule Forge.CodeActionTest do
  use ExUnit.Case, async: true

  alias Forge.CodeAction
  alias Forge.Document.Position
  alias Forge.Document.Range

  defp range(start_line, start_char, end_line, end_char) do
    Range.new(
      %Position{line: start_line, character: start_char},
      %Position{line: end_line, character: end_char}
    )
  end

  describe "to_refactor_data/4 and from_refactor_data/1" do
    test "round-trips a payload through to_ and from_" do
      data = CodeAction.to_refactor_data("file:///a.ex", 7, range(2, 3, 4, 5), Some.Module)

      assert {:ok, payload} = CodeAction.from_refactor_data(data)
      assert payload.module == "Elixir.Some.Module"
      assert payload.uri == "file:///a.ex"
      assert payload.version == 7
      assert payload.range == {{2, 3}, {4, 5}}
    end

    test "the encoded payload is JSON-object shaped (string keys only)" do
      data = CodeAction.to_refactor_data("file:///a.ex", 1, range(1, 1, 1, 2), Some.Module)

      assert Enum.all?(Map.keys(data), &is_binary/1)
      assert Enum.all?(Map.keys(data["range"]), &is_binary/1)
    end
  end

  describe "from_refactor_data/1 rejection" do
    test "rejects payloads that are not refactor data" do
      assert {:error, :invalid_data} = CodeAction.from_refactor_data(%{"provider" => "other"})
      assert {:error, :invalid_data} = CodeAction.from_refactor_data(%{"uri" => "file:///a.ex"})
      assert {:error, :invalid_data} = CodeAction.from_refactor_data(nil)
    end

    test "rejects our payloads with a missing field" do
      data = CodeAction.to_refactor_data("file:///a.ex", 1, range(1, 1, 1, 2), Some.Module)

      assert {:error, :invalid_data} = CodeAction.from_refactor_data(Map.delete(data, "module"))
      assert {:error, :invalid_data} = CodeAction.from_refactor_data(Map.delete(data, "range"))
    end

    test "rejects our payloads with a wrongly-typed field" do
      data = CodeAction.to_refactor_data("file:///a.ex", 1, range(1, 1, 1, 2), Some.Module)

      assert {:error, :invalid_data} = CodeAction.from_refactor_data(%{data | "version" => "1"})
      assert {:error, :invalid_data} = CodeAction.from_refactor_data(%{data | "module" => nil})

      assert {:error, :invalid_data} =
               CodeAction.from_refactor_data(%{data | "range" => %{"start" => "wat"}})
    end
  end
end
