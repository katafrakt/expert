defmodule Backend.User do
  @moduledoc """
  User management module.
  """

  defstruct [:id, :name, :email]

  @type t :: %__MODULE__{
          id: integer(),
          name: String.t(),
          email: String.t()
        }

  @doc """
  Creates a new user struct.
  """
  @spec new(integer(), String.t(), String.t()) :: t()
  def new(id, name, email) do
    %__MODULE__{id: id, name: name, email: email}
  end
end
