defmodule Engine.CodeAction.Handler do
  @moduledoc """
  Behaviour for individual code action definitions, invoked in `Engine.CodeAction.for_range/6`.
  """

  alias Forge.CodeAction
  alias Forge.CodeAction.Diagnostic
  alias Forge.Document
  alias Forge.Document.Range

  @doc """
  Returns the handler's actions for the given document and range.

  The diagnostics come from the request's context: those the client knows to overlap the range,
  which diagnostic-driven handlers match against to offer fixes.
  """
  @callback actions(Document.t(), Range.t(), [Diagnostic.t()], keyword()) :: [CodeAction.t()]

  @doc """
  Returns the code action kinds the handler can produce, matched against the request's `only` filter.
  """
  @callback kinds() :: [CodeAction.code_action_kind()]

  @doc """
  Returns the trigger kind the handler serves.
  """
  @callback trigger_kind() :: CodeAction.trigger_kind() | :all
end
