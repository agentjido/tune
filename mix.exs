defmodule Tune.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/agentjido/tune"
  @description "Evaluation and search pipelines for Elixir"

  def project do
    [
      app: :tune,
      version: @version,
      elixir: "~> 1.18",
      description: @description,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix], exclude_paths: ["test/support"]],
      name: "Tune",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/getting_started.md",
        "guides/programs.md",
        "guides/optimizers.md",
        "guides/compatibility.md",
        "guides/artifacts.md",
        "guides/host_integration.md",
        "guides/ui.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md"
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Mike Hostetler"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/tune",
        "Changelog" => "https://hexdocs.pm/tune/changelog.html",
        "Issues" => "#{@source_url}/issues"
      },
      files:
        ~w(lib mix.exs .formatter.exs README.md LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md guides)
    ]
  end

  def cli, do: [preferred_envs: ["test.examples": :test]]

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
      {:llm_db, "~> 2026.11.0"},
      {:zoi, "~> 0.19"},
      {:splode, "~> 0.3"},
      {:phoenix_playground, "~> 0.1.9", optional: true},
      {:plug, "~> 1.20 and >= 1.20.4", optional: true},
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
      "test.examples": ["test --only example"],
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
