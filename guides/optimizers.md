# Search strategies

`Tune.search/3` selects a strategy. It does not start the search. `Tune.tune/1`
validates and runs the full pipeline.

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

A generic search needs an explicit positive evaluation limit. Candidate
evaluation is sequential. Row evaluation can use bounded concurrency. This
keeps effect accounting deterministic and simple.

Tune can count calls that go through Tune programs and judge scores. An opaque
application runner owns any hidden external calls that it makes. The
application must enforce and report those limits.
