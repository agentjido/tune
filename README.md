# Tune

Tune is an Elixir library for evaluating programs and searching for better
configurations. Use it to measure a baseline, tune a configuration or prompt,
and compare the result on the same held-out cases.

Tune is in beta. The core runs in an Elixir application. The
optional local workbench is experimental.

## Install

Add Tune to the dependencies in your Mix project and run `mix deps.get`.

```elixir
{:tune, "~> 0.5.0"}
```

The [getting started guide](guides/getting_started.md) walks through a ticket
routing example, from selecting a threshold to saving it for the host app.
It also shows how to preview a prompt and score saved model answers.
Both examples run without provider credentials.

## Main capabilities

- Run Elixir functions or typed LLM programs against labeled cases.
- Score saved outputs without rerunning the program that produced them.
- Compare a search winner with its baseline on a held-out split.
- Search Elixir values with grid or genetic search. For structured prompts,
  search instructions and demonstrations with separate model-call limits.
- Preview Chat, JSON, and XML prompts. Export learned values as JSON artifacts.

## Architecture

Tune prepares prompts, runs cases, scores outputs, and selects candidates.
ReqLLM handles model requests and transport retries. The host application
controls credentials, tools, side effects, and deployment.

Tune uses Elixir throughout. An application can pass Nx or Axon values
through a runner. Exported learned values must be JSON-compatible.

## Start here

- [Getting started](guides/getting_started.md)
- [Programs and evaluation](guides/programs.md)
- [Search strategies](guides/optimizers.md)
- [Compatibility and boundaries](guides/compatibility.md)
- [Artifacts](guides/artifacts.md)
- [Host integration](guides/host_integration.md)
- [Optional local workbench](guides/ui.md)

For a longer offline demo, run this command from a Tune source checkout
after `mix deps.get`.

```sh
MIX_ENV=test mix run examples/01_dspy/01_03_bootstrap_qa/compare_demo.exs
```

This demo tunes a question-answering program using scripted ReqLLM replies.
It reports held-out accuracy, improved and regressed rows, and model calls.

See the [numbered offline examples](https://github.com/agentjido/tune/tree/v0.5.1/examples),
[typed prompt inspection](https://github.com/agentjido/tune/tree/v0.5.1/examples/01_dspy/01_01_extract_ticket),
and [grid search with paired comparison](https://github.com/agentjido/tune/tree/v0.5.1/examples/03_evolution/03_01_batch_grid).

## Experimental local workbench

Add Phoenix Playground to your Mix project and run `mix tune.ui`.
The workbench opens on the local machine. It keeps studies, runs, and
artifacts in memory and can preview a prompt with zero model calls.
Follow the [workbench guide](guides/ui.md) to try a study.

## Local checks

Run these commands from a Tune source checkout. The tests use scripted
responses.

```sh
mix deps.get
mix test
mix quality
mix docs
```

See [Contributing](CONTRIBUTING.md) and the [security policy](SECURITY.md)
for changes and reports.

## License

Tune uses [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0).
See the [changelog](CHANGELOG.md) for release changes.
