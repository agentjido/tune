# Tune

[![Hex.pm](https://img.shields.io/hexpm/v/tune.svg)](https://hex.pm/packages/tune)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/tune/)
[![CI](https://github.com/agentjido/tune/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/tune/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/tune.svg)](https://github.com/agentjido/tune/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> **Join the community!** Come chat about building AI tools with Elixir in
> [The Swarm: Elixir AI Collective](https://jido.run/discord) Discord server.

Tune measures and improves Elixir code, including LLM prompts.

You give Tune a function or an LLM program, some labeled examples, and a
score. Tune runs your code on the examples, searches for a better setting or
prompt, and then checks the winner against your current version on examples
the search did not see.

The same small API covers three jobs that usually need three tools:

- **An eval suite.** Score live code, saved answers, tool calls, or
  multi-turn transcripts, and gate a release on a paired comparison.
- **An evolution runner.** Run grid or genetic search over any Elixir value,
  from a config map to a route plan or an Axon learning rate.
- **A prompt optimizer.** Dial in instructions and few-shot examples with
  strategies modeled on DSPy and GEPA, in native Elixir with no Python.

> **Status:** Tune is in beta. The API can change before 1.0.

## Why Tune?

Changing a threshold, a model setting, or a prompt is easy. Knowing whether
the change made things better is hard. Tune gives you one workflow for that
question:

1. **Measure** the current version on labeled cases.
2. **Search** for a better setting, prompt, or set of examples.
3. **Compare** the winner with the current version on held-out cases.
4. **Save** the learned values as JSON and load them into your application.

Tune is plain Elixir. It needs no Python and no workflow engine. LLM calls go
through [ReqLLM](https://github.com/agentjido/req_llm), and your application
keeps control of credentials, tools, and deployment.

## Installation

Add `tune` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tune, "~> 0.5.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

Tune is tested with Elixir 1.18 on OTP 27 and Elixir 1.20 on OTP 29.

## Quick Start

This example picks a review threshold for a ticket router. It runs offline and
needs no model or credentials.

```elixir
route = fn config, risk ->
  if risk >= config.review_at, do: :review, else: :standard
end

validation = [
  %{id: "v1", input: 40, expected: :standard},
  %{id: "v2", input: 55, expected: :standard},
  %{id: "v3", input: 61, expected: :review},
  %{id: "v4", input: 80, expected: :review}
]

test = [
  %{id: "t1", input: 34, expected: :standard},
  %{id: "t2", input: 52, expected: :standard},
  %{id: "t3", input: 64, expected: :review},
  %{id: "t4", input: 90, expected: :review}
]

study =
  Tune.new(%{review_at: 50}, run: route)
  |> Tune.data(validation: validation, test: test)
  |> Tune.score(:accuracy, fn row, decision ->
    if decision == row.expected, do: 1, else: 0
  end)
  |> Tune.vary(review_at: [50, 60, 70])
  |> Tune.search(:grid)

{:ok, result} = Tune.tune(study)
result.value
#=> %{review_at: 60}

{:ok, report} = Tune.compare(study, result, split: :test)
Map.take(report.metrics.accuracy, [:baseline_mean, :challenger_mean, :status])
#=> %{status: :improved, baseline_mean: 0.75, challenger_mean: 1.0}

{:ok, artifact} = Tune.dump(result)
{:ok, json} = Tune.Artifact.encode(artifact)
```

Builder calls such as `Tune.data/2` and `Tune.vary/2` only return a new
`%Tune{}` value. Work happens in `Tune.evaluate/2`, `Tune.tune/1`, and
`Tune.compare/3`. The [getting started guide](guides/getting_started.md)
walks through each step and shows how to load the saved JSON.

## Features

- **Evaluate** Elixir functions, typed LLM programs, or saved outputs against
  labeled cases with named scores. Built-in judges score faithfulness and
  context precision for retrieval.
- **Evolve** any Elixir value with grid or genetic search. You supply the
  genome callbacks; Tune handles selection, elitism, stop rules, snapshots,
  and cancellation.
- **Tune prompts** with more than a dozen strategies, including bootstrap
  few-shot, MIPROv2, COPRO, SIMBA, and GEPA-style reflective search. Every
  model-calling search runs under an explicit call limit, and teacher and
  proposal models stay separate from the model you are tuning.
- **Ensemble** several tuned programs and vote on the answer.
- **Compare** a search winner with its baseline on a held-out split, case by
  case.
- **Preview** the exact Chat, JSON, or XML prompt before any model call.
- **Export** learned values as versioned JSON artifacts.
- **Experiment** in an optional local workbench with `mix tune.ui`
  (experimental).

## How it fits together

Tune prepares prompts, runs cases, scores outputs, and selects candidates.
ReqLLM sends model requests and handles transport retries. The host
application owns credentials, tools, side effects, and deployment. Tune has no
Jido dependency; a [Jido](https://github.com/agentjido/jido) host passes its
own run function to Tune.

## Documentation

- [Getting started](guides/getting_started.md) — tune one setting and save it
- [Programs](guides/programs.md) — build and tune typed LLM programs
- [Search strategies](guides/optimizers.md) — strategies, limits, and objectives
- [Artifacts](guides/artifacts.md) — what Tune saves and checks on load
- [Host integration](guides/host_integration.md) — use Tune inside your application
- [Compatibility](guides/compatibility.md) — how DSPy, GEPA, and Jido workflows map to Tune
- [Local workbench](guides/ui.md) — the experimental browser workbench

[HexDocs](https://hexdocs.pm/tune/) also has Livebook guides for genetic
search, prompt tuning, retrieval scoring, and agent evaluation suites.

## Examples

The source repository has numbered examples that run offline with local
fixtures or scripted ReqLLM replies:

- [All offline examples](https://github.com/agentjido/tune/tree/v0.5.0/examples)
- [Typed prompt inspection](https://github.com/agentjido/tune/tree/v0.5.0/examples/01_dspy/01_01_extract_ticket)
- [Grid search with paired comparison](https://github.com/agentjido/tune/tree/v0.5.0/examples/03_evolution/03_01_batch_grid)

From a source checkout, this demo tunes a question-answering prompt and
reports held-out accuracy and model calls:

```bash
MIX_ENV=test mix run examples/01_dspy/01_03_bootstrap_qa/compare_demo.exs
```

## Development

```bash
# Install dependencies
mix deps.get

# Run tests (scripted responses, no credentials)
mix test

# Run the offline examples
mix test.examples

# Run quality checks (format, compile warnings, credo, dialyzer)
mix quality

# Generate documentation
mix docs
```

## Contributing

Bug reports and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request. Report
security issues as described in [SECURITY.md](SECURITY.md). See the
[changelog](CHANGELOG.md) for release changes.

## License

Copyright 2026 Mike Hostetler

Licensed under the Apache License, Version 2.0.
[License text](https://github.com/agentjido/tune/blob/main/LICENSE).
