# Tune

Tune is a lazy evaluation and search pipeline for Elixir.

Tune can evaluate and tune structured LLM programs on ReqLLM. It can also
search plain Elixir values with no LLM. A pipeline is immutable. Builder
functions only add data. `Tune.evaluate/2` and `Tune.tune/1` do the work.

```elixir
study =
  Tune.new(program, model: target, teacher: teacher)
  |> Tune.data(train: train, validation: validation, test: test)
  |> Tune.score(:answer, &answer_score/2, range: {0.0, 1.0})
  |> Tune.score(:citations, &citation_score/2, range: {0.0, 1.0})
  |> Tune.select(weighted: [answer: 0.8, citations: 0.2])
  |> Tune.search(:bootstrap_few_shot, max_bootstrapped_demos: 4)
  |> Tune.limit(model_calls: 200)

{:ok, baseline} = Tune.evaluate(study)
{:ok, result} = Tune.tune(study)
```

The public workflow has twelve function names:

- `new`
- `data`
- `vary`
- `score`
- `select`
- `search`
- `limit`
- `preview`
- `evaluate`
- `tune`
- `dump`
- `load`

## Main capabilities

- Typed structured prompts with Zoi.
- Chat, JSON, and XML prompt adapters.
- Exact prompt inspection before a model call.
- Named scores, text feedback, failure scores, and retained row errors.
- Faithfulness and context-precision judge scores through ReqLLM.
- Fifteen prompt and example search targets.
- Generic genetic search for maps and structs.
- Enumerable and stream data sources.
- Opaque Nx and Axon values in application runners.
- Versioned JSON artifacts for learned, JSON-compatible values.

## Architecture

- Runtime owns typed programs, model roles, execution, and predictions.
- Evaluation owns cases, scores, selection, observations, and summaries.
- Search owns one shared Study. Program strategies and genetic search keep
  separate algorithm mechanics.
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
mix run examples/generic_genetic.exs
```

The first example shows the exact prompt for each adapter. The second example
tunes a two-step grounded QA program with two scores and scripted ReqLLM
replies. The third example tunes a plain Elixir configuration.

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
