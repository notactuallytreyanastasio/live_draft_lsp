defmodule LiveDraftLsp.Server do
  @moduledoc """
  LSP server that watches for markdown file saves and POSTs content
  to a Phoenix blog for live preview.
  """
  use GenLSP

  alias GenLSP.Requests.Initialize
  alias GenLSP.Notifications.Initialized
  alias GenLSP.Notifications.TextDocumentDidSave
  alias GenLSP.Structures.InitializeResult
  alias GenLSP.Structures.ServerCapabilities
  alias GenLSP.Structures.TextDocumentSyncOptions
  alias GenLSP.Structures.SaveOptions

  require Logger

  @impl true
  def init(lsp, config) do
    {:ok,
     assign(lsp,
       url: config.url,
       token: config.token
     )}
  end

  @impl true
  def handle_request(%Initialize{}, lsp) do
    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           save: %SaveOptions{include_text: true}
         }
       },
       server_info: %{name: "LiveDraftLSP", version: "0.1.0"}
     }, lsp}
  end

  @impl true
  def handle_request(_request, lsp) do
    {:reply, nil, lsp}
  end

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    GenLSP.log(lsp, "[LiveDraftLSP] Initialized — watching for markdown saves")
    {:noreply, lsp}
  end

  @impl true
  def handle_notification(%TextDocumentDidSave{params: params}, lsp) do
    uri = params.text_document.uri
    text = params.text

    if markdown?(uri) && text do
      slug = derive_slug(uri)

      if slug do
        GenLSP.log(lsp, "[LiveDraftLSP] Posting draft for #{slug}")

        Task.start(fn ->
          post_draft(lsp.assigns.url, lsp.assigns.token, slug, text)
        end)
      end
    end

    {:noreply, lsp}
  end

  @impl true
  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  defp markdown?(uri), do: String.ends_with?(uri, ".md")

  defp derive_slug(uri) do
    filename =
      uri
      |> URI.parse()
      |> Map.get(:path)
      |> URI.decode()
      |> Path.basename(".md")

    case Regex.run(~r/^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-(.+)$/, filename) do
      [_, slug] -> slug
      nil -> filename
    end
  end

  defp post_draft(url, token, slug, content) do
    case Req.post(url,
           json: %{slug: slug, content: content},
           headers: [{"x-auth-token", token}]
         ) do
      {:ok, %{status: 200}} ->
        Logger.info("[LiveDraftLSP] Posted draft for #{slug}")

      {:ok, %{status: status, body: body}} ->
        Logger.error("[LiveDraftLSP] Failed for #{slug}: #{status} — #{inspect(body)}")

      {:error, error} ->
        Logger.error("[LiveDraftLSP] HTTP error for #{slug}: #{inspect(error)}")
    end
  end
end
