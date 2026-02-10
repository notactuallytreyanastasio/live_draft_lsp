defmodule LiveDraftLsp.SocketClient do
  @moduledoc """
  WebSocket client that speaks Phoenix Channel protocol.
  Maintains a persistent connection and sends draft updates over the channel.
  Connects lazily on first use and handles disconnects gracefully.
  """
  use WebSockex
  require Logger

  defstruct [:token, :slug, :ref, :joined]

  def start_link(url, token) do
    ws_url = build_ws_url(url, token)
    state = %__MODULE__{token: token, slug: nil, ref: 0, joined: false}
    WebSockex.start_link(ws_url, __MODULE__, state, name: __MODULE__, handle_initial_conn_failure: true)
  end

  @doc "Ensure the client is started, then join a channel for the given slug"
  def join(slug) do
    if alive?() do
      WebSockex.cast(__MODULE__, {:join, slug})
    else
      Logger.warning("[SocketClient] Not connected, can't join #{slug}")
    end
  end

  @doc "Send draft content over the channel"
  def push_draft(content) do
    if alive?() do
      WebSockex.cast(__MODULE__, {:push_draft, content})
    else
      Logger.warning("[SocketClient] Not connected, dropping draft")
    end
  end

  defp alive? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # --- Callbacks ---

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("[SocketClient] Connected to Phoenix")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"event" => "phx_reply", "payload" => %{"status" => "ok"}, "ref" => ref}} ->
        if ref == state.ref do
          Logger.info("[SocketClient] Joined channel successfully")
          {:ok, %{state | joined: true}}
        else
          {:ok, state}
        end

      {:ok, %{"event" => "phx_error"} = payload} ->
        Logger.error("[SocketClient] Channel error: #{inspect(payload)}")
        {:ok, %{state | joined: false}}

      {:ok, _other} ->
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:join, slug}, state) do
    topic = "live_draft:#{slug}"
    ref = state.ref + 1

    msg =
      Jason.encode!(%{
        topic: topic,
        event: "phx_join",
        payload: %{token: state.token},
        ref: ref
      })

    {:reply, {:text, msg}, %{state | slug: slug, ref: ref, joined: false}}
  end

  @impl true
  def handle_cast({:push_draft, content}, %{joined: true, slug: slug} = state) do
    ref = state.ref + 1
    topic = "live_draft:#{slug}"

    msg =
      Jason.encode!(%{
        topic: topic,
        event: "draft:update",
        payload: %{content: content},
        ref: ref
      })

    {:reply, {:text, msg}, %{state | ref: ref}}
  end

  def handle_cast({:push_draft, _content}, %{joined: false} = state) do
    Logger.warning("[SocketClient] Not joined yet, dropping draft")
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("[SocketClient] Disconnected: #{inspect(reason)}, reconnecting in 3s...")
    :timer.sleep(3000)
    {:reconnect, %{state | joined: false}}
  end

  # Build the WebSocket URL from the HTTP API URL
  # https://bobbby.online/api/live-draft -> wss://bobbby.online/socket/websocket?token=...
  defp build_ws_url(api_url, token) do
    uri = URI.parse(api_url)

    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    host = uri.host
    port = uri.port

    port_str =
      cond do
        scheme == "wss" and port in [443, nil] -> ""
        scheme == "ws" and port in [80, nil] -> ""
        port != nil -> ":#{port}"
        true -> ""
      end

    "#{scheme}://#{host}#{port_str}/socket/websocket?token=#{token}"
  end
end
