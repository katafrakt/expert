defmodule Forge.Ast.Detection.StructReference do
  @moduledoc """
  A struct reference is a `%` followed by some valid module path.
  """
  use Forge.Ast.Detection

  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Ast.Tokens
  alias Forge.Document.Position

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    case Ast.cursor_context(analysis, position) do
      {:ok, {:struct, context}} ->
        match?({:ok, _}, reference_length(context))

      {:ok, {:local_or_var, [?_ | _rest] = possible_module_struct}} ->
        # a reference to `%__MODULE`, often in a function head, as in def foo(%__)

        starts_with_percent? =
          analysis.document
          |> Tokens.prefix_stream(position)
          |> Enum.take(2)
          |> Enum.any?(fn
            {:percent, :%, _} -> true
            _ -> false
          end)

        starts_with_percent? and possible_dunder_module(possible_module_struct) and
          (ancestor_is_def?(analysis, position) or ancestor_is_type?(analysis, position))

      _ ->
        false
    end
  end

  def possible_dunder_module(charlist) do
    String.starts_with?("__MODULE__", to_string(charlist))
  end

  @doc """
  Measures the module path in a `:struct` cursor context, while also providing authority on what
  actually counts as a *struct reference*. Expects a `{:struct, _}` context from `Code.Fragment.cursor_context/1`.

  Returns `{:ok, length}` (# of characters following `%`) for a valid module path, or `:error`
  otherwise — a bare `%`, or a lowercase call segment such as `%Foo.bar`, which is a remote call
  carrying a stray `%` rather than a struct.

  ## Examples

      iex> alias Forge.Ast.Detection.StructReference
      iex> StructReference.reference_length(~c"Foo")
      {:ok, 3}
      iex> StructReference.reference_length({:dot, {:alias, ~c"Foo"}, []})
      {:ok, 4}
      iex> StructReference.reference_length({:dot, {:alias, ~c"Foo"}, ~c"bar"})
      :error
  """
  @spec reference_length(term()) :: {:ok, non_neg_integer()} | :error
  def reference_length([]), do: :error
  def reference_length(name) when is_list(name), do: {:ok, length(name)}
  def reference_length({:local_or_var, name}), do: {:ok, length(name)}
  # add one for the leading `@`
  def reference_length({:module_attribute, name}), do: {:ok, length(name) + 1}
  def reference_length({:alias, name}) when is_list(name), do: {:ok, length(name)}

  def reference_length({:alias, base, name}) do
    with {:ok, base_length} <- reference_length(base) do
      # add one for the dot between the base and the trailing alias segment
      {:ok, base_length + 1 + length(name)}
    end
  end

  def reference_length({:dot, inner, []}) do
    with {:ok, inner_length} <- reference_length(inner) do
      # add one for the trailing period
      {:ok, inner_length + 1}
    end
  end

  def reference_length(_), do: :error
end
