defmodule Forge.CodeAction do
  alias Forge.Document.Changes
  alias Forge.Document.Position
  alias Forge.Document.Range

  defstruct [:title, :kind, :changes, :uri, :data]

  @type code_action_kind :: GenLSP.Enumerations.CodeActionKind.t()

  @type trigger_kind :: GenLSP.Enumerations.CodeActionTriggerKind.t()

  @typedoc """
  JSON-serializable payload round-tripped through the client for `codeAction/resolve`. Actions
  carrying `data` defer their edits until resolved; actions carrying `changes` ship their edits
  inline.
  """
  @type data :: %{optional(String.t()) => term()}

  @typedoc """
  A deferred refactor payload parsed from its round-tripped `data`. Coordinates are the raw
  one-based line/character integers from the original request; the caller validates them against
  the current document.
  """
  @type refactor_data :: %{
          module: String.t(),
          uri: Forge.uri(),
          version: non_neg_integer(),
          range: {{integer(), integer()}, {integer(), integer()}}
        }

  @type t :: %__MODULE__{
          title: String.t(),
          kind: code_action_kind,
          changes: Changes.t() | nil,
          uri: Forge.uri(),
          data: data() | nil
        }

  # Marks a deferred action owned by the refactor resolver. Callers routing the
  # request head-match this tag directly; this module owns the *payload* schema
  # (the field set and range structure) so those aren't spelled out in more than
  # one place.
  @refactor_provider "refactor"

  @spec new(Forge.uri(), String.t(), code_action_kind(), Changes.t()) :: t()
  def new(uri, title, kind, changes) do
    %__MODULE__{uri: uri, title: title, changes: changes, kind: kind}
  end

  @spec deferred(Forge.uri(), String.t(), code_action_kind(), data()) :: t()
  def deferred(uri, title, kind, data) do
    %__MODULE__{uri: uri, title: title, kind: kind, data: data}
  end

  @doc """
  Builds the `data` payload for a deferred refactor action.

  The payload round-trips through the client and is parsed back by `from_refactor_data/1`.
  """
  @spec to_refactor_data(Forge.uri(), non_neg_integer(), Range.t(), module()) :: data()
  def to_refactor_data(uri, version, %Range{} = range, module)
      when is_binary(uri) and is_integer(version) and is_atom(module) do
    %{
      "provider" => @refactor_provider,
      "module" => Atom.to_string(module),
      "uri" => uri,
      "version" => version,
      "range" => to_range_data(range)
    }
  end

  @doc """
  Parses a round-tripped deferred refactor payload into its fields.

  Returns `{:error, :invalid_data}` when the payload is not well-formed refactor data.
  Coordinates are returned as raw integers; the caller validates them against the current document.
  """
  @spec from_refactor_data(term()) :: {:ok, refactor_data()} | {:error, :invalid_data}
  def from_refactor_data(%{
        "provider" => @refactor_provider,
        "module" => module,
        "uri" => uri,
        "version" => version,
        "range" => range
      })
      when is_binary(module) and is_binary(uri) and is_integer(version) do
    case to_coordinates(range) do
      {:ok, coordinates} ->
        {:ok, %{module: module, uri: uri, version: version, range: coordinates}}

      :error ->
        {:error, :invalid_data}
    end
  end

  def from_refactor_data(_data), do: {:error, :invalid_data}

  defp to_range_data(%Range{start: start_pos, end: end_pos}) do
    %{"start" => to_position_data(start_pos), "end" => to_position_data(end_pos)}
  end

  defp to_position_data(%Position{line: line, character: character}) do
    %{"line" => line, "character" => character}
  end

  defp to_coordinates(%{"start" => start_pos, "end" => end_pos}) do
    with {:ok, start_coord} <- to_coordinate(start_pos),
         {:ok, end_coord} <- to_coordinate(end_pos) do
      {:ok, {start_coord, end_coord}}
    end
  end

  defp to_coordinates(_range), do: :error

  defp to_coordinate(%{"line" => line, "character" => character})
       when is_integer(line) and is_integer(character) do
    {:ok, {line, character}}
  end

  defp to_coordinate(_position), do: :error
end
