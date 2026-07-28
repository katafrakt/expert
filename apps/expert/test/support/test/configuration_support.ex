defmodule Expert.Test.ConfigurationSupport do
  @moduledoc false

  alias Expert.Configuration
  alias GenLSP.Structures.ClientCapabilities
  alias GenLSP.Structures.CodeActionClientCapabilities
  alias GenLSP.Structures.TextDocumentClientCapabilities

  @doc """
  Installs a client configuration whose `textDocument.codeAction.resolveSupport` is
  `resolve_support`, returning the stored configuration.
  """
  def put_resolve_support(resolve_support) do
    %ClientCapabilities{
      text_document: %TextDocumentClientCapabilities{
        code_action: %CodeActionClientCapabilities{
          resolve_support: resolve_support
        }
      }
    }
    |> Configuration.new("test-client")
    |> Configuration.set()
  end
end
