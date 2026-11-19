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
    published_guides =
      guide_toc()
      |> Enum.map(fn {section, guides} ->
        {section, Enum.filter(guides, fn {_title, path} -> File.regular?(path) end)}
      end)
      |> Enum.reject(fn {_section, guides} -> guides == [] end)

    guide_extras =
      for {_section, guides} <- published_guides,
          {title, path} <- guides,
          do: {path, title: title}

    guide_groups =
      for {section, guides} <- published_guides, do: {section, Enum.map(guides, &elem(&1, 1))}

    project_pages = ["CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md"]

    [
      main: "readme",
      source_ref: "v#{@version}",
      extra_section: "Guides",
      extras: ["README.md" | guide_extras] ++ project_pages,
      groups_for_extras: guide_groups ++ [Project: project_pages]
    ]
  end

  # Add a guide at its listed path to include it in ExDoc.
  defp guide_toc do
    [
      {"API Basics",
       [
         {"Quickstart", "guides/getting_started.md"},
         {"Evaluate a Function", "guides/api/evaluate-a-function.livemd"},
         {"Programs", "guides/programs.md"},
         {"Typed Predictors", "guides/api/typed-predictors.livemd"},
         {"Search API", "guides/optimizers.md"},
         {"Artifacts", "guides/artifacts.md"}
       ]},
      {"Elixir Tuning",
       [
         {"Batch Settings", "guides/examples/batch-settings.livemd"},
         {"Axon Learning Rate", "guides/examples/axon-learning-rate.livemd"}
       ]},
      {"Genetic Evolution",
       [
         {"Evolve a Word", "guides/examples/evolve-a-word.livemd"},
         {"Pack a Kit", "guides/examples/pack-a-kit.livemd"},
         {"Delivery Routes", "guides/examples/delivery-routes.livemd"},
         {"Dispatch Policies", "guides/examples/dispatch-policies.livemd"}
       ]},
      {"LLM Tuning",
       [
         {"Ticket Routing", "guides/examples/ticket-routing.livemd"},
         {"QA Prompts", "guides/examples/qa-prompts.livemd"},
         {"Multi-Hop QA", "guides/examples/multi-hop-qa.livemd"},
         {"Risk Policy", "guides/examples/risk-policy.livemd"}
       ]},
      {"Evaluation",
       [
         {"Replay JSONL", "guides/examples/replay-jsonl.livemd"},
         {"Score Retrieval", "guides/examples/score-retrieval.livemd"}
       ]},
      {"Agentic Eval Suites",
       [
         {"Build an Eval Suite", "guides/examples/build-an-eval-suite.livemd"},
         {"Score Tool Calls", "guides/examples/score-tool-calls.livemd"},
         {"Score Transcripts", "guides/examples/score-transcripts.livemd"},
         {"Gate a Release", "guides/examples/gate-a-release.livemd"}
       ]},
      {"Integration",
       [
         {"Host Integration", "guides/host_integration.md"},
         {"Deploy a Router", "guides/integration/deploy-a-router.livemd"},
         {"Local Workbench", "guides/ui.md"},
         {"Compatibility", "guides/compatibility.md"}
       ]}
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
      {:git_hooks, "~> 0.9.0", only: :dev, runtime: false},
      {:git_ops, "~> 2.12.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
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
