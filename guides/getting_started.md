# Quickstart

This guide tunes one setting of a plain Elixir function and checks the new
setting on cases that the search did not see. It needs no model, no
provider credentials, and no network access.

Add Tune to your Mix project and fetch it:

```text
{:tune, "~> 0.5.0"}
```

```sh
mix deps.get
```

The beta test matrix uses Elixir 1.18 with OTP 27 and Elixir 1.20 with OTP 29.

## The problem

A support team sends risky tickets to manual review. A ticket router gives
each ticket a risk score and sends it to review when the score reaches a
threshold. The current threshold is 50, and it sends too many tickets to
review. You have a few labeled tickets and want to know if 60 or 70 works
better.

Save the code in this guide as `tune_threshold.exs` in your project, then run
`mix run tune_threshold.exs`.

## Describe the current setting

Start with the current configuration and the function that uses it. Tune
calls the function once per case with the candidate configuration and the
case input.

```elixir
baseline = %{review_at: 50}

route = fn config, risk ->
  if risk >= config.review_at, do: :review, else: :standard
end
```

Each case has an `id`, an `input`, and an `expected` value. Keep two separate
splits. The search uses `validation` to pick a winner. The final check uses
`test`.

```elixir
validation = [
  %{id: "t-101", input: 40, expected: :standard},
  %{id: "t-102", input: 55, expected: :standard},
  %{id: "t-103", input: 61, expected: :review},
  %{id: "t-104", input: 80, expected: :review}
]

test = [
  %{id: "t-201", input: 34, expected: :standard},
  %{id: "t-202", input: 52, expected: :standard},
  %{id: "t-203", input: 64, expected: :review},
  %{id: "t-204", input: 90, expected: :review}
]
```

## Build the study

Each builder call returns a new `%Tune{}` value and does no work.

```elixir
study =
  Tune.new(baseline, run: route)
  |> Tune.data(validation: validation, test: test)
  |> Tune.score(:accuracy, fn row, decision ->
    if decision == row.expected, do: 1, else: 0
  end)
  |> Tune.vary(review_at: [50, 60, 70])
  |> Tune.search(:grid)
```

- `Tune.new/2` takes the target value and the `:run` function.
- `Tune.data/2` names the splits. Tune never splits data for you.
- `Tune.score/4` adds a named score. A two-argument scorer receives the case
  and the output. Higher scores win by default.
- `Tune.vary/2` declares which fields a search may change, and to what.
- `Tune.search/3` picks the strategy. `:grid` tries every combination once.

## Run the search

`Tune.tune/1` runs the search on the validation split and returns a
`%Tune.Result{}`.

```elixir
{:ok, result} = Tune.tune(study)

IO.inspect(result.value, label: "winner")

for candidate <- result.history do
  IO.inspect(candidate.evaluation.selected_score, label: "review_at #{candidate.value.review_at}")
end
```

```text
winner: %{review_at: 60}
review_at 50: 0.75
review_at 60: 1.0
review_at 70: 0.75
```

`result.value` is the original map with the winning setting applied.
`result.history` holds every evaluated candidate in order. Ties keep the
earlier candidate.

## Check the winner on held-out cases

A validation score shows which candidate won the search. It does not show how
the winner does on new tickets. `Tune.compare/3` runs the original setting and
the winner on the same test cases and pairs the results by case ID.

```elixir
{:ok, report} = Tune.compare(study, result, split: :test)

accuracy = report.metrics.accuracy
IO.inspect({accuracy.baseline_mean, accuracy.challenger_mean, accuracy.status})
IO.inspect(report.rows["t-202"].metrics.accuracy.status, label: "t-202")
```

```text
{0.75, 1.0, :improved}
t-202: :improved
```

The split is required. Both versions route the tickets with scores 34, 64,
and 90 correctly. Only the winner sends ticket `t-202`, with a score of 52, to
the standard queue. Check `accuracy.paired_count` against
`length(report.case_ids)` to confirm that every case produced a pair.

## Save the setting

`Tune.dump/1` turns the result into a versioned `Tune.Artifact` that holds
only the learned values. The host application loads it into its own fresh
configuration.

```elixir
{:ok, artifact} = Tune.dump(result)
{:ok, json} = Tune.Artifact.encode(artifact)

{:ok, saved} = Tune.Artifact.decode(json)
{:ok, config} = Tune.load(saved, %{review_at: 50})
IO.inspect(config)
```

```text
%{review_at: 60}
```

Write `json` to a file or a database row to keep it between deploys. The
routing function stays in your code.

## Next steps

- [Search API](optimizers.md) covers limits, objectives, and the other strategies.
- [Artifacts](artifacts.md) explains what Tune saves and the checks it makes on load.
- [Programs](programs.md) shows how to tune typed LLM programs with the same pipeline.
