defmodule LiveDraftLsp.Config do
  @moduledoc """
  Loads config from .live-draft.json in the current directory,
  falling back to environment variables.
  """

  def load do
    file_config = load_file()

    %{
      url:
        file_config["url"] ||
          System.get_env("LIVE_DRAFT_URL", "https://bobbby.online/api/live-draft"),
      token:
        file_config["token"] ||
          System.get_env("LIVE_DRAFT_TOKEN", "")
    }
  end

  defp load_file do
    path = Path.join(File.cwd!(), ".live-draft.json")

    case File.read(path) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> %{}
    end
  rescue
    _ -> %{}
  end
end
