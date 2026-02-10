# LiveDraftLSP

Type in Zed, see it live on your blog. Every word you type streams to your Phoenix app in real time via a persistent WebSocket channel.

```
Zed editor                         Your blog
    |                                   |
    |  (type a word + space)            |
    |  textDocument/didChange           |
    +---> LiveDraftLSP ----WebSocket--> Phoenix Channel
              (Elixir)      (persistent)    |
                                            v
    open .md file  --->  join channel   PubSub broadcast
    switch files   --->  rejoin             |
    type + space   --->  push content       v
    Cmd+S          --->  push content   LiveView re-renders
                                        with pulsing LIVE badge
```

## Architecture

Three pieces work together:

1. **Phoenix Channel** (your blog) — `LiveDraftChannel` receives markdown over a persistent WebSocket, renders it, broadcasts via PubSub, LiveView updates in real time
2. **LiveDraftLSP** (this repo) — Elixir LSP server that connects a WebSocket to your blog on startup, joins a channel per post, and pushes content on word boundaries
3. **zed-live-draft** — thin Rust/WASM Zed extension that launches the LSP for Markdown files

The key insight: one persistent WebSocket connection handles everything. No HTTP request per word. The LSP opens the socket once when Zed starts, joins a channel when you open a markdown file, and pushes content as you type. If you switch to a different post file, it re-joins for the new slug.

## Prerequisites

- Elixir >= 1.14 installed locally
- A Phoenix blog with the live-draft channel deployed (see [Server Setup](#server-setup))
- Zed editor

## Setup

### 1. Build and install the LSP

```bash
git clone https://github.com/notactuallytreyanastasio/live_draft_lsp.git
cd live_draft_lsp
mix deps.get
mix escript.build
cp live_draft_lsp ~/.local/bin/
```

Make sure `~/.local/bin` is on your PATH. Add to your shell profile if needed:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Verify it's found:

```bash
which live_draft_lsp
```

### 2. Install the Zed extension

Clone the extension:

```bash
git clone https://github.com/notactuallytreyanastasio/zed-live-draft.git
```

In Zed:
1. Open Command Palette (Cmd+Shift+P)
2. Type `zed: install dev extension`
3. Select the `zed-live-draft` folder you just cloned

The extension registers a language server for Markdown files. When you open any `.md` file, Zed will launch `live_draft_lsp` in the background.

### 3. Configure your blog project

Create a `.live-draft.json` in the root of your blog repo:

```json
{
  "url": "https://yourblog.com/api/live-draft",
  "token": "your-secret-token-here"
}
```

For local development:

```json
{
  "url": "http://localhost:4000/api/live-draft",
  "token": "dev-live-draft-token"
}
```

The `url` field is used to derive the WebSocket URL. The LSP converts `https://yourblog.com/...` to `wss://yourblog.com/socket/websocket?token=...` automatically.

Add `.live-draft.json` to your `.gitignore` (it contains your auth token).

Alternatively, use environment variables instead of the config file:

```bash
export LIVE_DRAFT_URL="https://yourblog.com/api/live-draft"
export LIVE_DRAFT_TOKEN="your-secret-token-here"
```

### 4. Start writing

1. Start your Phoenix blog (`mix phx.server`)
2. Open a post markdown file in Zed (e.g. `priv/static/posts/2026-02-09-00-00-00-my-post.md`)
3. Open `http://localhost:4000/post/my-post` in a browser
4. Start typing — every time you hit space, period, or enter, the page updates live
5. A pulsing red **LIVE** badge appears in the title bar while streaming

## How it works

**On LSP startup**, the `SocketClient` opens a persistent WebSocket to your Phoenix app's `/socket/websocket` endpoint with your auth token.

**When you open a markdown file**, the LSP joins a Phoenix Channel topic `live_draft:<slug>`. When you switch to a different markdown file, it joins the new channel.

**On every keystroke**, Zed sends the full document to the LSP via `textDocument/didChange`. The LSP checks if the text ends with a word boundary (space, period, newline). If so, it pushes the content over the channel with `draft:update`.

**On save** (Cmd+S), it always pushes regardless of the last character, as a guaranteed sync point.

**On the server**, the `LiveDraftChannel`:
1. Authenticates on join via token
2. On `draft:update`, passes content to `Blog.LiveDraft`
3. `Blog.LiveDraft` renders the markdown with Earmark, stores in ETS, broadcasts via PubSub

**In the browser**, the `PostLive` LiveView:
1. Subscribes to `live_draft:#{slug}` PubSub topic on mount
2. Replaces the post HTML when a broadcast arrives
3. Shows a pulsing LIVE badge
4. Reverts to the static file content after 2 minutes of inactivity

**Reconnection**: If the WebSocket drops, WebSockEx automatically reconnects. The channel re-join happens on the next keystroke or file open.

## Server Setup

Your Phoenix blog needs these additions. All changes are in the blog repo.

### New files

**`lib/blog/live_draft.ex`** — GenServer with ETS cache:

```elixir
defmodule Blog.LiveDraft do
  use GenServer

  @table :live_drafts

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end
    {:ok, %{}}
  end

  def update(slug, content) do
    html = render_markdown(content)
    now = DateTime.utc_now()
    :ets.insert(@table, {slug, content, html, now})
    Phoenix.PubSub.broadcast!(Blog.PubSub, "live_draft:#{slug}", {:live_draft_update, slug, html, now})
    {:ok, html}
  end

  def get(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, _, html, at}] ->
        if DateTime.diff(DateTime.utc_now(), at) < 120, do: {:ok, html, at}, else: :stale
      [] -> :none
    end
  end
end
```

**`lib/blog_web/channels/live_draft_channel.ex`** — Phoenix Channel:

```elixir
defmodule BlogWeb.LiveDraftChannel do
  use Phoenix.Channel

  def join("live_draft:" <> slug, %{"token" => token}, socket) do
    expected = Application.get_env(:blog, :live_draft_api_token)
    if token == expected && token != nil do
      {:ok, assign(socket, :slug, slug)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_in("draft:update", %{"content" => content}, socket) do
    {:ok, _} = Blog.LiveDraft.update(socket.assigns.slug, content)
    {:reply, :ok, socket}
  end
end
```

### Modified files

**`lib/blog_web/channels/user_socket.ex`** — add channel route:

```elixir
channel "live_draft:*", BlogWeb.LiveDraftChannel
```

**`lib/blog/application.ex`** — add `Blog.LiveDraft` to children (after PubSub)

**`lib/blog_web/router.ex`** — add HTTP route in the `/api` scope (kept as fallback):

```elixir
post "/live-draft", LiveDraftController, :update
```

**`config/runtime.exs`** — add inside the prod block:

```elixir
config :blog, :live_draft_api_token, System.get_env("LIVE_DRAFT_TOKEN")
```

**`config/config.exs`** — add dev default:

```elixir
config :blog, :live_draft_api_token, "dev-live-draft-token"
```

**`lib/blog_web/live/post_live.ex`** — subscribe to PubSub topic, handle updates:

```elixir
# In mount, inside if connected?(socket):
Phoenix.PubSub.subscribe(Blog.PubSub, "live_draft:#{slug}")

# New handle_info clauses:
def handle_info({:live_draft_update, _slug, html, _at}, socket) do
  {:noreply, assign(socket, html: html, live_draft_active: true)}
end
```

### Deploy

Set the secret on your hosting provider:

```bash
# Fly.io
fly secrets set LIVE_DRAFT_TOKEN="$(openssl rand -hex 32)"

# Gigalixir
gigalixir config:set LIVE_DRAFT_TOKEN="$(openssl rand -hex 32)"
```

Use the same token value in your local `.live-draft.json`.

## Post filename convention

The LSP derives the post slug from the filename. It expects the blog naming pattern:

```
YYYY-MM-DD-HH-MM-SS-slug-words-here.md
```

The slug is everything after the timestamp. For example:

| Filename | Slug |
|---|---|
| `2026-02-09-00-00-00-my-first-post.md` | `my-first-post` |
| `2025-12-25-14-30-00-building-this-blog.md` | `building-this-blog` |
| `random-notes.md` | `random-notes` (fallback: full basename) |

## Troubleshooting

**LSP not starting in Zed?**
- Check `which live_draft_lsp` returns a path
- Open Zed's log (Cmd+Shift+P > "zed: open log") and search for "live-draft"

**Posts not updating?**
- Verify `.live-draft.json` exists in your project root with the correct URL and token
- Check the Phoenix server logs for `[LiveDraft] Author joined channel` messages
- Make sure the slug in the URL matches an existing post (the post must be in `@allowed_slugs`)

**WebSocket not connecting?**
- The LSP converts your `url` config to a WebSocket URL: `https://x.com/api/...` becomes `wss://x.com/socket/websocket?token=...`
- Check that `/socket/websocket` is accessible on your blog (it uses the existing `UserSocket`)
- If behind a reverse proxy, ensure WebSocket upgrade headers are forwarded

**LIVE badge not appearing?**
- The badge only shows when a `live_draft_update` PubSub message arrives
- Open the browser's network tab to confirm WebSocket messages are arriving
- The badge disappears after 2 minutes of inactivity (staleness timeout)

## License

MIT
