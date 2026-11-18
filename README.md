# Tune

Tune is a lazy evaluation and search pipeline for Elixir.

Tune can evaluate and tune structured LLM programs on ReqLLM. It can also
search plain Elixir values with no LLM. A pipeline is immutable. Builder
functions add declarations. Call `Tune.evaluate/2`, `Tune.tune/1`, or
`Tune.compare/3` to run the pipeline.

Run the offline search and compare the winner on a separate test split:

```sh
mix deps.get
MIX_ENV=test mix run examples/lazy_structured_prompt.exs
```

The example uses scripted ReqLLM replies and needs no provider credentials.
It prints the paired results and the optimized prompt. The first lines are:

```text
Test answer accuracy: 0.3333333333333333 -> 0.6666666666666666
Answer rows: 2 improved, 1 regressed
Model calls: 6 -> 6
```

```elixir
study =
  Tune.new(program, model: target, teacher: teacher)
  |> Tune.data(train: train, validation: validation, test: test)
  |> Tune.score(:answer, &answer_score/2, argument: :output, range: {0.0, 1.0})
  |> Tune.score(:citations, &citation_score/2, argument: :output, range: {0.0, 1.0})
  |> Tune.select(weighted: [answer: 0.8, citations: 0.2])
  |> Tune.search(:bootstrap_few_shot, max_bootstrapped_demos: 4)
  |> Tune.limit(model_calls: 200)

{:ok, winner} = Tune.tune(study)
{:ok, comparison} = Tune.compare(study, winner, split: :test)
```

The public workflow uses these functions:

- `new`
- `data`
- `replay`
- `vary`
- `score`
- `select`
- `search`
- `limit`
- `preview`
- `evaluate`
- `tune`
- `compare`
- `dump`
- `load`

## Main capabilities

- Typed structured prompts with Zoi.
- Chat, JSON, and XML prompt adapters.
- Exact prompt inspection before a model call.
- Named scores, text feedback, failure scores, and retained row errors.
- Faithfulness and context-precision judge scores through ReqLLM.
- Fifteen prompt and example search targets.
- Grid and genetic search for maps and structs.
- Enumerable and stream data sources.
- Opaque Nx and Axon values in application runners.
- Versioned JSON artifacts for learned, JSON-compatible values.

## Architecture

- Runtime owns typed programs, model roles, execution, and predictions.
- Evaluation owns cases, scores, selection, observations, and summaries.
- Search owns shared limits, candidate history, and selection.
- Artifact owns the only persisted format and applies all learned values atomically.

Dependencies point in that order. Runtime does not depend on Evaluation or Search.
Evaluation accepts an opaque runner and does not know a search algorithm.

Tune uses no Python runtime. It has no runtime dependency on Jido, Nx, Axon,
`jido_eval`, or `jido_evolve`.

Tune does not own model transport, provider retries, tools, agent loops,
storage, model training, or deployment. ReqLLM owns model transport and
transport retries. The application owns runtime code, credentials, tools, and
side effects.

## Start here

Run the offline examples from this directory:

```sh
mix run examples/inspect_prompts.exs
MIX_ENV=test mix run examples/lazy_structured_prompt.exs
mix run examples/generic_grid.exs
mix run examples/generic_genetic.exs
```

The examples show prompt inspection, grounded QA tuning and comparison,
and search over plain Elixir configurations.

Read these guides for more detail:

- [Programs and evaluation](guides/programs.md)
- [Search strategies](guides/optimizers.md)
- [Compatibility and boundaries](guides/compatibility.md)
- [Artifacts](guides/artifacts.md)
- [Host integration](guides/host_integration.md)
- [Optional local workbench](guides/ui.md)

## Optional local workbench

Tune can run a local multi-route workbench with Phoenix Playground. Add
`phoenix_playground` to the host dependencies, then start it:

```sh
mix tune.ui
```

The workbench builds studies, accepts JSON data, previews exact prompts, runs
evaluation or search, and downloads Tune artifacts. It binds only to the local
computer and keeps state in memory. See the [workbench guide](guides/ui.md) for
the route list and extension boundary.

## Local checks

```sh
mix deps.get
mix test
mix quality
mix docs
```

All default tests are offline. They use scripted replies through ReqLLM.

## Status

Tune is local and unpublished. No license has been selected.
