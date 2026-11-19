# Search API

A search is a lazy pipeline. `Tune.vary/2` declares what may change,
`Tune.search/3` picks a strategy, `Tune.limit/2` bounds the work, and
`Tune.tune/1` runs it. The result is one immutable `%Tune.Result{}`. The
examples in this guide run offline.

## Search a small grid

A job runner has two settings, `batch_size` and `workers`. The runner function
returns throughput and cost for one workload. Each workload is a
`{batch_size, workers}` pair that runs best at those settings.

```elixir
measure = fn config, {size, workers} ->
  %{
    jobs_per_s: 100 - abs(config.batch_size - size) - 3 * abs(config.workers - workers),
    cost: config.workers * 2 + config.batch_size / 8
  }
end

study =
  Tune.new(%{batch_size: 1, workers: 1}, run: measure)
  |> Tune.data(validation: [{7, 2}, {9, 2}], test: [{6, 2}, {8, 3}])
  |> Tune.vary(batch_size: 1..16, workers: [1, 2, 3])
  |> Tune.score(:jobs_per_s, & &1.jobs_per_s, range: {0, 100})
  |> Tune.search(:grid)

{:ok, result} = Tune.tune(study)

IO.inspect(result.value)
IO.inspect(result.best.evaluation.selected_score)
IO.inspect({length(result.history), result.stop_reason, result.complete?})
```

```text
%{workers: 2, batch_size: 7}
99.0
{48, :completed, true}
```

`:grid` visits every combination once: 16 batch sizes times 3 worker counts.
It walks fields in alphabetical order. Ranges follow their direction, and
choices follow list order. `:grid` takes no strategy options.

The search reads only the `validation` split. Use `Tune.compare/3` with
`split: :test` to check the winner on held-out cases, as in the
[Quickstart](getting_started.md).

## Read the result

A `%Tune.Result{}` has these fields:

- `value` is the target with the winning parameters applied.
- `parameters` holds only the winning parameter values.
- `best` is the winning `%Tune.Candidate{}`, with its `evaluation`.
- `history` lists every evaluated candidate in order.
- `stop_reason` says why the search ended. `complete?` is `true` only when it
  finished without hitting a limit.
- `calls` and `usage` total the managed model calls and tokens.

A candidate wins only after a complete, eligible validation evaluation. Ties
keep the earlier candidate.

## Limit the work

`Tune.limit/2` accepts `evaluations`, `model_calls`, `cases`, `concurrency`,
`row_timeout`, `row_calls`, `deadline`, `steps`, and `seed`. When a limit stops
a search, Tune returns the best candidate it has fully evaluated.

```elixir
{:ok, short} = study |> Tune.limit(evaluations: 10) |> Tune.tune()

IO.inspect(short.value)
IO.inspect({length(short.history), short.stop_reason, short.complete?})
```

```text
%{workers: 2, batch_size: 3}
{10, :evaluation_limit, false}
```

The grid stopped after 10 candidates, before it reached `batch_size: 7`.
Check `complete?` before you treat a result as the best of the whole space.

## Choose the objective

With one score, the search uses it. With two or more, call `Tune.select/2`.

```elixir
two_scores = Tune.score(study, :cost, & &1.cost, direction: :minimize, range: {0.0, 10.0})

{:error, error} = Tune.tune(two_scores)
IO.puts(Exception.message(error))

{:ok, cheapest} = two_scores |> Tune.select(:cost) |> Tune.tune()
IO.inspect(cheapest.value)

{:ok, balanced} =
  two_scores
  |> Tune.select(weighted: [jobs_per_s: 0.7, cost: 0.3])
  |> Tune.tune()

IO.inspect(balanced.value)
```

```text
:selector: multiple scores require Tune.select/2
%{workers: 1, batch_size: 1}
%{workers: 1, batch_size: 7}
```

`Tune.select(study, :cost)` picks one score. `direction: :minimize` makes
lower cost win, so the cheapest setting wins. The weighted selector trades
some throughput for a lower worker cost. A weighted selector combines scores,
and every selected score needs an explicit `range` so Tune can normalize it. Raw scores stay unchanged
in each observation.

## Run genetic search

`:genetic` samples and evolves candidates. It needs an explicit positive
`evaluations` limit. Add a `seed` to repeat the same run.

```elixir
{:ok, evolved} =
  Tune.new(%{batch_size: 1, workers: 1}, run: measure)
  |> Tune.data(validation: [{7, 2}, {9, 2}])
  |> Tune.vary(batch_size: 1..64, workers: [1, 2, 3, 4])
  |> Tune.score(:jobs_per_s, & &1.jobs_per_s)
  |> Tune.search(:genetic, population_size: 8, generations: 5)
  |> Tune.limit(evaluations: 48, seed: 7)
  |> Tune.tune()

IO.inspect({evolved.value, evolved.best.evaluation.selected_score, evolved.stop_reason})
```

```text
{%{workers: 2, batch_size: 9}, 99.0, :completed}
```

Variation spaces include integer ranges such as `1..64`, choice lists,
`{:float, min, max}`, `{:log_float, min, max}`, `{:subset, values}`, and
`{:text, opts}`. Genetic options are `population_size`, `generations`,
`mutation_rate`, `crossover_rate`, `elitism`, `tournament_size`,
`initial_population`, `mutate`, `crossover`, `valid?`, `select_parent`,
`target_score`, `patience`, `candidate_concurrency`, and `cancel`. Pass
`initial_population` with `mutate` and `crossover` to evolve arbitrary
Elixir values.

## Search a program

For a `Tune.Program` target, pass a strategy tag to `Tune.search/3`. These
strategies change only declared parameters: instructions, demonstrations, and
`Tune.Parameter` values. They never change the target model, the adapter, or
your code. Tune never splits data, and it rejects validation rows whose inputs
also appear in training data.

| Tag | What it changes | Splits | Model roles | Main options |
| --- | --- | --- | --- | --- |
| `:labeled_few_shot` | Adds labeled demonstrations | train | none | `k`, `sample` |
| `:bootstrap_few_shot` | Adds demonstrations from passing teacher runs | train | teacher | `max_bootstrapped_demos`, `max_labeled_demos`, `max_rounds`, `accept_score` |
| `:bootstrap_few_shot_random_search` | Picks the best of several seeded demonstration sets | train, validation | teacher | `num_candidate_programs`, plus bootstrap options with a required `accept_score` |
| `:bootstrap_few_shot_optuna` | Chooses demonstration sets with native TPE | train, validation | teacher | `num_demo_sets`, `num_trials`, `n_startup`, plus bootstrap options with a required `accept_score` |
| `:knn_few_shot` | Picks the nearest training rows at run time | train | teacher when the result runs | `k`, `max_bootstrapped_demos`, `max_labeled_demos`, `vectorizer` |
| `:copro` | Rewrites instructions, one predictor at a time | train, validation | proposal | `breadth`, `depth`, `evidence_examples`, `predictors` |
| `:signature_optimizer` | Rewrites one named predictor's instructions | train, validation | proposal | `predictor` (required), `breadth`, `depth`, `evidence_examples` |
| `:mipro_v2` | Searches instructions and demonstrations together | train, validation | teacher, proposal | `num_candidates`, `num_trials`, `minibatch_size`, `minibatch_full_eval_steps`, `n_startup`, `evidence_examples`, plus bootstrap options with a required `accept_score` |
| `:infer_rules` | Adds rules learned from examples to instructions | train, validation | teacher, proposal | `num_candidates`, `num_rules`, plus bootstrap options with a required `accept_score` |
| `:simba` | Adds a demonstration or a rule where outputs vary | train, validation | proposal | `bsz`, `num_candidates`, `max_steps`, `max_demos`, `temperature`, `num_final`, `strategies` |
| `:gepa` | Evolves instructions from feedback with a Pareto pool and merges | train, validation | proposal | `max_iterations`, `minibatch_size`, `use_merge`, `merge_every`, `predictors` |
| `:avatar` | Rewrites one predictor from good and bad traces | train, validation | proposal | `predictor`, `upper_bound`, `lower_bound` (all required), `max_iters`, `max_positive`, `max_negative` |
| `:playbook` | Grows a bounded list of lessons in one parameter | train, validation | proposal | `parameter` (required), `rounds`, `max_lessons`, `max_new`, `max_lesson_bytes`, `max_total_bytes` |
| `:anything` | Revises one declared JSON value | train, validation | proposal | `parameter` (required), `objective`, `max_iterations`, `minibatch_size` |
| `:ensemble` | Combines the target with member programs | none | none | `members` (required), `size`, `seed`, `reducer` |

Prompt search means the instruction strategies: `:copro`,
`:signature_optimizer`, `:mipro_v2`, `:gepa`, and `:simba`. Pass the teacher
and proposal model configurations to `Tune.new/2` next to `:model`. They are
separate from the target configuration and never replace it.

Every strategy that calls a model needs an explicit `model_calls` limit.
Tune checks this before it reads data or makes a call:

```elixir
{:ok, classifier} =
  Tune.Predictor.new(
    signature: [
      instructions: "Classify the support ticket.",
      inputs: [ticket: Zoi.string()],
      outputs: [label: Zoi.enum(["billing", "bug"])]
    ]
  )

target = [model: "openai:gpt-4o-mini", adapter: Tune.Adapter.Chat]

prompt_search =
  Tune.new(classifier, model: target)
  |> Tune.data(
    train: [%{input: %{ticket: "I was charged twice."}, expected: %{label: "billing"}}],
    validation: [%{input: %{ticket: "The app crashes on login."}, expected: %{label: "bug"}}]
  )
  |> Tune.score(:correct, fn row, output -> if output == row.expected, do: 1, else: 0 end)
  |> Tune.search(:gepa, max_iterations: 4)

{:error, error} = Tune.tune(prompt_search)
IO.puts(Exception.message(error))

{:error, error} = prompt_search |> Tune.limit(model_calls: 200, seed: 0) |> Tune.tune()
IO.puts(Exception.message(error))
```

```text
:model_calls: a model call limit is required for search with model calls
:proposal: this optimizer requires an explicit proposal model configuration
```

Add `proposal: proposal_config` to `Tune.new/2` to run it. The `model_calls`
budget covers target, teacher, and proposal calls together, and failed
attempts count. When the budget runs out, Tune returns the best eligible
candidate so far with `complete?: false`. If no candidate finished an eligible
validation evaluation, `Tune.tune/1` returns `Tune.Error.Optimization.Failed`
with the partial result in its `report` field. A seed controls Tune's own
choices, not provider output.

## Next steps

- [Programs](programs.md) shows how to declare the parameters these strategies change.
- [Artifacts](artifacts.md) saves a result and loads it into fresh code.
- [QA prompts](examples/qa-prompts.livemd) runs `:mipro_v2` offline with scripted replies.
