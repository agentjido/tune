# Search strategies

`Tune.search/3` selects a strategy. It does not start the search. `Tune.tune/1`
validates and runs the full pipeline.

Use `:grid` to test a short list of settings, such as the support ticket
threshold in [Getting started](getting_started.md#search-plain-elixir-values).
Use `:genetic` for a larger search space with a set evaluation limit. For a
typed predictor with labeled training examples, start with
`:labeled_few_shot` to test whether adding demonstrations helps.

```elixir
{:ok, result} =
  Tune.new(program, model: target, teacher: teacher, proposal: proposal)
  |> Tune.data(train: train, validation: validation)
  |> Tune.score(:quality, &quality/2)
  |> Tune.search(:mipro_v2, num_candidates: 8, accept_score: 1.0)
  |> Tune.limit(model_calls: 500, seed: 0)
  |> Tune.tune()
```

## Shared rules

- The target model and adapter stay fixed for one search.
- Teacher and proposal models are separate and explicit.
- A model-calling strategy needs an explicit model-call limit.
- Candidate search needs explicit validation data.
- Example-building strategies can use training data only.
- Tune never makes an automatic data split.
- Tune never uses training data as validation data.
- Test data is not part of search.
- A candidate wins only after one complete, eligible validation evaluation.
- Failed validation rows make a candidate ineligible by default.
- A score can set `failure_score` to keep that candidate eligible.
- Ties keep the earlier candidate.
- Random choices use local seeded state.
- A seed controls Tune choices. It does not control provider output.

The result is a `%Tune.Result{}`. `result.value` is the selected program or
configuration. `result.best` is the selected candidate. `result.history` keeps
all completed candidates. The result also has call totals, usage, completion
state, and a stop reason.

If a limit stops the search, Tune returns the best fully evaluated eligible
candidate. If no eligible candidate exists, Tune returns an optimization error
that contains the result report.

## Structured program strategies

| Search tag | Main change | Data | Model roles |
| --- | --- | --- | --- |
| `:labeled_few_shot` | Add labeled demonstrations | train | none |
| `:bootstrap_few_shot` | Build demonstrations from teacher traces | train | teacher |
| `:bootstrap_few_shot_random_search` | Search demonstration sets | train, validation | teacher |
| `:bootstrap_few_shot_optuna` | Search demonstration sets with native TPE | train, validation | teacher |
| `:knn_few_shot` | Select close examples at run time | train | teacher at run time |
| `:copro` | Search instructions by coordinate | train, validation | proposal |
| `:signature_optimizer` | Search one predictor instruction | train, validation | proposal |
| `:mipro_v2` | Search instructions and demonstrations | train, validation | teacher, proposal |
| `:infer_rules` | Learn explicit rules from examples | train, validation | teacher, proposal |
| `:simba` | Improve weak examples with local feedback | train, validation | proposal |
| `:gepa` | Reflect on feedback and keep a Pareto pool | train, validation | proposal |
| `:avatar` | Rewrite from positive and negative traces | train, validation | proposal |
| `:playbook` | Learn a bounded list of lessons | train, validation | proposal |
| `:anything` | Search one declared JSON-compatible value | train, validation | proposal |
| `:ensemble` | Combine explicit member programs | none | none |

These strategies change only declared program parameters. They do not change
application code, tools, model weights, the target model, or the target
adapter. No strategy needs Python.

## Generic genetic search

The generic strategy searches declared map or struct values.

```elixir
{:ok, result} =
  Tune.new(%{batch_size: 10, threshold: 0.5}, run: &MyBenchmark.run/1)
  |> Tune.data(validation: fn -> MyBenchmark.validation_batches() end)
  |> Tune.vary(
    batch_size: 1..100,
    threshold: {:float, 0.0, 1.0}
  )
  |> Tune.score(:throughput, & &1.throughput)
  |> Tune.search(:genetic,
    population_size: 20,
    generations: 10,
    mutation_rate: 0.1
  )
  |> Tune.limit(evaluations: 220, seed: 0)
  |> Tune.tune()
```

Built-in spaces include integer ranges, float ranges, log-float ranges,
choices, bounded subsets, and text choices. The strategy supports population
size, generations, mutation rate, crossover rate, elitism, tournament size,
deadline, and a cancellation callback.

Genetic search needs an explicit positive evaluation limit. Tune reads the
validation data once per study. Row concurrency is available for each
candidate. Use `candidate_concurrency` to evaluate independent candidates in
parallel in a study without managed model calls.

## Search a finite grid

Use `:grid` for integer ranges and explicit choices. It visits each
combination once, in alphabetical field order. A range follows its declared
direction. Choices follow list order, with duplicates removed. Use an
evaluation limit to stop after the first N configurations.

```elixir
study =
  Tune.new(%{batch_size: 1}, run: &MyBenchmark.run/2)
  |> Tune.data(validation: validation, test: test)
  |> Tune.vary(batch_size: 1..16)
  |> Tune.score(:quality, fn _case, output -> output.quality end)
  |> Tune.search(:grid)

{:ok, winner} = Tune.tune(study)
{:ok, comparison} = Tune.compare(study, winner, split: :test)
```

Run the [grid search example](https://github.com/mikehostetler/tune/tree/v0.5.0/examples/03_evolution/03_01_batch_grid)
from the Tune root.

```sh
MIX_ENV=test mix run examples/03_evolution/03_01_batch_grid/demo.exs
```

## Evolve a seeded population

Pass `initial_population` to use your exact seed values in order. With named
variations, seeds must agree outside those fields. To vary arbitrary Elixir
values, omit named variations and supply whole-genome callbacks:

```elixir
pipeline =
  Tune.new(hd(seeds), run: &MyBenchmark.run/2, on_progress: &MyReport.record/1)
  |> Tune.data(validation: cases)
  |> Tune.score(:fitness, &MyBenchmark.score/2)
  |> Tune.search(:genetic,
    initial_population: seeds,
    mutate: &MyGenome.mutate/2,
    crossover: &MyGenome.crossover/3,
    valid?: &MyGenome.valid?/1,
    generations: 12,
    target_score: 0.9,
    patience: 4
  )
  |> Tune.limit(evaluations: length(seeds) * 13, seed: 42)

{:ok, result} = Tune.tune(pipeline)
```

Mutation and crossover receive the current random state as their last argument
and return `{genome, random_state}`. The optional `select_parent` callback
receives eligible candidates and that state. It returns
`{candidate_id, random_state}`. With a single score, the target threshold
uses the score's original direction and scale. With weighted selection, the
threshold uses the combined selection value.

The progress callback receives `:candidate_evaluated` and
`:generation_evaluated` events. A generation event includes its number,
ordered population, best candidate, and whether it completed. The seed
population is generation zero. A host can persist these snapshots without
waiting for the final result.

Tune counts managed model calls, including failed attempts. ReqLLM owns
transport retries within a call. An opaque runner owns external calls and
detached resources. Keep data factories and variation callbacks bounded so the
study can reach its worker deadline and cancellation checks.

Run the [seeded word search](https://github.com/mikehostetler/tune/tree/v0.5.0/examples/03_evolution/03_02_evolve_string)
and [hyperparameter reload](https://github.com/mikehostetler/tune/tree/v0.5.0/examples/03_evolution/03_05_axon_training)
demos from the Tune root.

```sh
MIX_ENV=test mix run examples/03_evolution/03_02_evolve_string/demo.exs
MIX_ENV=test mix run examples/03_evolution/03_05_axon_training/demo.exs
```
