# Getting started

Use Tune to test a change to an Elixir program and check the result on data
that the search did not see. This guide uses an existing Mix project and
runs without provider credentials.

Add `{:tune, "~> 0.5.0"}` to your dependencies and run `mix deps.get`.
The beta test matrix uses Elixir 1.18 with OTP 27 and Elixir 1.20 with OTP 29.

## Search plain Elixir values

A support team sends high-risk tickets to manual review. A threshold of 50
sends too many tickets to review. Use labeled cases to select a threshold,
then check it on a separate set.

Save this code as `tune_threshold.exs` in your Mix project. Run
`mix run tune_threshold.exs`.

```elixir
baseline = %{review_at: 50}

route = fn config, risk ->
  if risk >= config.review_at, do: :review, else: :standard
end

validation = [
  %{input: 40, expected: :standard},
  %{input: 50, expected: :standard},
  %{input: 61, expected: :review},
  %{input: 80, expected: :review}
]

test = [
  %{input: 34, expected: :standard},
  %{input: 52, expected: :standard},
  %{input: 64, expected: :review},
  %{input: 90, expected: :review}
]

study =
  Tune.new(baseline, run: route)
  |> Tune.data(validation: validation, test: test)
  |> Tune.score(:accuracy, fn row, decision ->
    if row.expected == decision, do: 1, else: 0
  end)
  |> Tune.vary(review_at: [50, 60, 70])
  |> Tune.search(:grid)

{:ok, winner} = Tune.tune(study)
{:ok, report} = Tune.compare(study, winner, split: :test)

IO.inspect({winner.value, report.baseline.selected_score, report.challenger.selected_score})
```

Expected output:

```text
{%{review_at: 60}, 0.75, 1.0}
```

Tune selects 60 using the validation cases. On the test cases, both settings
route the three cases with scores of 34, 64, and 90 correctly. The new
setting also sends the case with a score of 52 to the standard queue.

## Save and reload the selected setting

Append this code to `tune_threshold.exs` and run it again. This step saves the
selected threshold in `ticket-routing.json` and applies it to a fresh copy
of the original settings.

```elixir
{:ok, artifact} = Tune.dump(winner)
{:ok, json} = Tune.Artifact.encode(artifact)
File.write!("ticket-routing.json", json)

{:ok, saved} = File.read!("ticket-routing.json") |> Tune.Artifact.decode()
{:ok, config} = Tune.load(saved, baseline)
IO.inspect(config)
```

The last line is `%{review_at: 60}`. The host keeps the routing function in
Elixir. See [artifacts](artifacts.md) for the fields Tune saves and the
checks it makes when it loads them.

## Preview a prompt and score a saved answer

For a support ticket classifier, preview the messages for one ticket. Then
score a saved answer. The preview and the saved-answer evaluation both run
without a model call.

Save this code as `tune_ticket.exs` and run `mix run tune_ticket.exs`.

```elixir
{:ok, predictor} =
  Tune.Predictor.new(
    signature: [
      instructions: "Classify this support ticket as billing or bug.",
      inputs: [ticket: Zoi.string()],
      outputs: [label: Zoi.enum(["billing", "bug"])]
    ]
  )

ticket = %{ticket: "I was charged twice for my subscription."}
model = [model: "openai:gpt-4o", adapter: Tune.Adapter.Chat]
{:ok, prepared} = Tune.preview(Tune.new(predictor, model: model), ticket)
IO.inspect(Enum.map(prepared.context.messages, & &1.role))

saved_answers = [
  %{id: "ticket-1042", input: ticket, output: %{"label" => "billing"}, expected: %{"label" => "billing"}},
  %{
    id: "ticket-1043",
    input: %{ticket: "The app closes when I attach a PDF."},
    output: %{"label" => "billing"},
    expected: %{"label" => "bug"}
  }
]

{:ok, evaluation} =
  Tune.replay(saved_answers)
  |> Tune.score(:exact_match, fn row, output -> if output == row.expected, do: 1, else: 0 end)
  |> Tune.evaluate(:test)

IO.inspect(evaluation.selected_score)
```

The final score is `0.5`. Open `evaluation.observations` to inspect each
ticket's output and score. Use [programs and evaluation](programs.md) to
evaluate fresh answers or add another metric. Use the
[workbench guide](ui.md) for the browser workflow.
