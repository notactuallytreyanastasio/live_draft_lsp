defmodule LiveDraftLsp.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_draft_lsp,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LiveDraftLsp.Application, []}
    ]
  end

  defp deps do
    [
      {:gen_lsp, "~> 0.11.0"},
      {:websockex, "~> 0.4.3"},
      {:jason, "~> 1.2"}
    ]
  end

  defp escript do
    [main_module: LiveDraftLsp.CLI]
  end
end
