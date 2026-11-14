defmodule Tune.MixProject do
  use Mix.Project

  def project do
    [
      app: :tune,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Typed and optimizable language-model programs built on ReqLLM",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix, :llm_db], exclude_paths: ["test/support"]],
      name: "Tune",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/programs.md",
        "guides/optimizers.md",
        "guides/compatibility.md",
        "guides/artifacts.md",
        "guides/host_integration.md"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "examples"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req_llm, "~> 1.30"},
      {:zoi, "~> 0.19"},
      {:splode, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.7"},
      {:plug, "~> 1.16", only: :test},
      {:nx, "~> 1.0", only: :test},
      {:axon, "~> 0.9", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ],
      q: ["quality"]
    ]
  end
end
