defmodule LiveDraftLsp.CLI do
  @moduledoc """
  Escript entry point. Starts the LSP server on stdio.
  """

  def main(_args) do
    {:ok, _} = Application.ensure_all_started(:live_draft_lsp)

    config = LiveDraftLsp.Config.load()

    {:ok, _pid} =
      GenLSP.start_link(LiveDraftLsp.Server, config, [])

    Process.sleep(:infinity)
  end
end
