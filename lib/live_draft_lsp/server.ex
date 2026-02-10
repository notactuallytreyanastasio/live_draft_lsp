defmodule LiveDraftLsp.Server do
  @moduledoc """
  LSP server that streams markdown content to a Phoenix blog as you type.
  Uses a persistent WebSocket channel instead of HTTP per-word.
  Fires on every word boundary (space, period, newline) and on save.
  """
  use GenLSP

  alias GenLSP.Requests.Initialize
  alias GenLSP.Notifications.Initialized
  alias GenLSP.Notifications.TextDocumentDidSave
  alias GenLSP.Notifications.TextDocumentDidChange
  alias GenLSP.Notifications.TextDocumentDidOpen
  alias GenLSP.Structures.InitializeResult
  alias GenLSP.Structures.ServerCapabilities
  alias GenLSP.Structures.TextDocumentSyncOptions
  alias GenLSP.Structures.SaveOptions
  alias GenLSP.Enumerations.TextDocumentSyncKind

  require Logger

  @word_boundary_chars [" ", ".", "\n", "\r\n"]

  @impl true
  def init(lsp, config) do
    {:ok,
     assign(lsp,
       url: config.url,
       token: config.token,
       current_slug: nil
     )}
  end

  @impl true
  def handle_request(%Initialize{}, lsp) do
    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           change: TextDocumentSyncKind.full(),
           save: %SaveOptions{include_text: true}
         }
       },
       server_info: %{name: "LiveDraftLSP", version: "0.3.0"}
     }, lsp}
  end

  @impl true
  def handle_request(_request, lsp) do
    {:reply, nil, lsp}
  end

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    # Connect to Phoenix once the LSP is initialized
    case LiveDraftLsp.SocketClient.start_link(lsp.assigns.url, lsp.assigns.token) do
      {:ok, _pid} ->
        GenLSP.log(lsp, "[LiveDraftLSP] Connected — streaming on word boundaries")

      {:error, reason} ->
        GenLSP.log(lsp, "[LiveDraftLSP] Failed to connect: #{inspect(reason)} — will retry on use")
    end

    {:noreply, lsp}
  end

  # When a markdown file is opened, join the channel for that slug
  @impl true
  def handle_notification(%TextDocumentDidOpen{params: params}, lsp) do
    uri = params.text_document.uri

    if markdown?(uri) do
      slug = derive_slug(uri)

      if slug do
        LiveDraftLsp.SocketClient.join(slug)
        GenLSP.log(lsp, "[LiveDraftLSP] Joined channel for #{slug}")
        {:noreply, assign(lsp, current_slug: slug)}
      else
        {:noreply, lsp}
      end
    else
      {:noreply, lsp}
    end
  end

  # didChange fires on every keystroke with full document content
  @impl true
  def handle_notification(%TextDocumentDidChange{params: params}, lsp) do
    uri = params.text_document.uri

    lsp =
      if markdown?(uri) do
        case params.content_changes do
          [%{text: text} | _] when is_binary(text) ->
            slug = derive_slug(uri)
            lsp = maybe_rejoin(slug, lsp)

            if ends_at_word_boundary?(text) do
              LiveDraftLsp.SocketClient.push_draft(text)
            end

            lsp

          _ ->
            lsp
        end
      else
        lsp
      end

    {:noreply, lsp}
  end

  # didSave always pushes as a guaranteed sync point
  @impl true
  def handle_notification(%TextDocumentDidSave{params: params}, lsp) do
    uri = params.text_document.uri
    text = params.text

    lsp =
      if markdown?(uri) && text do
        slug = derive_slug(uri)
        lsp = maybe_rejoin(slug, lsp)
        LiveDraftLsp.SocketClient.push_draft(text)
        lsp
      else
        lsp
      end

    {:noreply, lsp}
  end

  @impl true
  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  # If the user switched to a different markdown file, join the new channel
  defp maybe_rejoin(slug, lsp) when slug != nil do
    if slug != lsp.assigns.current_slug do
      LiveDraftLsp.SocketClient.join(slug)
      assign(lsp, current_slug: slug)
    else
      lsp
    end
  end

  defp maybe_rejoin(_slug, lsp), do: lsp

  defp ends_at_word_boundary?(text) do
    Enum.any?(@word_boundary_chars, &String.ends_with?(text, &1))
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
end
