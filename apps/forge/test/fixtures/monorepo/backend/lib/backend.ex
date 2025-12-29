defmodule Backend do
  @moduledoc """
  The main Backend module.

  This module lives in a subdirectory of a monorepo.
  """

  @doc """
  Returns a greeting message.

  ## Examples

      iex> Backend.hello()
      :world

  """
  def hello do
    :world
  end

  @doc """
  Adds two numbers together.
  """
  @spec add(number(), number()) :: number()
  def add(a, b) do
    a + b
  end
end
