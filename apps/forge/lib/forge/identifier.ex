defmodule Forge.Identifier do
  @moduledoc """
  Generates globally unique identifiers using UUIDv7.

  UUIDv7 IDs are time-ordered (Unix timestamp in most significant bits),
  making them naturally sortable and allowing timestamp extraction.
  """

  @doc """
  Returns the next globally unique identifier as a raw 16-byte binary.
  """
  @spec next_global!() :: binary()
  def next_global! do
    Uniq.UUID.uuid7(:raw)
  end

  @doc """
  Extracts the Unix timestamp (in milliseconds) from a UUIDv7 identifier.
  """
  @spec to_unix(binary()) :: non_neg_integer()
  def to_unix(id) when is_binary(id) do
    {:ok, %Uniq.UUID{time: time}} = Uniq.UUID.info(id, :struct)
    time
  end

  @doc """
  Converts a UUIDv7 identifier to a DateTime.
  """
  @spec to_datetime(binary()) :: DateTime.t()
  def to_datetime(id) when is_binary(id) do
    id
    |> to_unix()
    |> DateTime.from_unix!(:millisecond)
  end

  @doc """
  Converts a UUIDv7 identifier to an Erlang datetime tuple.
  """
  @spec to_erl(binary()) :: :calendar.datetime()
  def to_erl(id) when is_binary(id) do
    %DateTime{year: year, month: month, day: day, hour: hour, minute: minute, second: second} =
      to_datetime(id)

    {{year, month, day}, {hour, minute, second}}
  end
end
