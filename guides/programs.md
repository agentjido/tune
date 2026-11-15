# Programs and evaluation

## Typed predictors

A `Tune.Predictor` has one typed signature. The signature declares ordered
input fields, ordered output fields, and instructions.

```elixir
{:ok, predictor} =
  Tune.Predictor.new(
    signature: [
      instructions: "Classify the support ticket.",
      inputs: [ticket: Zoi.string()],
      outputs: [
        label: Zoi.enum(["billing", "bug", "other"]),
        confidence: Zoi.float()
      ]
    ]
  )
```

Fields use JSON-compatible Zoi schemas. Tune normalizes field names once. A
validated output is a string-keyed map.

## Model configuration

Each tuning run has one fixed target model configuration. A search can also
have separate teacher and proposal configurations.

```elixir
{:ok, target} =
  Tune.ModelConfig.new(
    model: "openai:gpt-4o-mini",
    adapter: Tune.Adapter.JSON,
    adapter_options: [mode: :structured],
    request_options: [temperature: 0.0]
  )
```

The model configuration selects the adapter. Tune does not change the target
model or adapter during a search. ReqLLM owns the provider request and transport
retries.

Chat, JSON, and XML adapters only render a prompt and parse a reply. They do not
retry, repair, or call a model. Repair and extraction must be explicit program
steps.

## Prompt inspection

`Tune.preview/2` prepares one request and makes no model call.

```elixir
{:ok, prepared} =
  predictor
  |> Tune.new(model: target)
  |> Tune.preview(%{ticket: "I was charged twice."})

Enum.each(prepared.context.messages, &IO.inspect/1)
```

For a composed program, give the predictor name with its inputs:

```elixir
Tune.preview(pipeline, {"answer", %{question: question, facts: facts}})
```

## Composed programs

A composed program is an application struct that implements `Tune.Program`.
Its control flow is normal Elixir code.

```elixir
@behaviour Tune.Program

def call(_program, inputs, execution) do
  with {:ok, %{"facts" => facts}, execution} <-
         Tune.Execution.predict(execution, "extract", inputs) do
    Tune.Execution.predict(execution, "answer", %{
      "question" => inputs["question"],
      "facts" => facts
    })
  end
end
```

The application declares its predictors and learned values through the other
`Tune.Program` callbacks. Tune can then update those values without changing
the program code.

## Data and scores

`Tune.data/2` accepts `:train`, `:validation`, and `:test` data. A value can be
an Enumerable or a zero-arity function that returns an Enumerable. Use a
factory when Tune must read a stream for more than one candidate. Give an
explicit `cases` or `evaluations` limit for an infinite source.

```elixir
pipeline =
  Tune.new(program, model: target)
  |> Tune.data(test: fn -> File.stream!("cases.jsonl") |> Stream.map(&decode/1) end)
  |> Tune.score(:correct, &correct?/2, failure_score: 0.0)
  |> Tune.limit(cases: 1_000, concurrency: 4, row_timeout: 30_000)

{:ok, evaluation} = Tune.evaluate(pipeline)
```

A program row is a `%Tune.Case{}` or a map with `:input`, optional
`:expected`, and optional `:id`. Expected values go only to the score callback.

Each `Tune.score/4` call adds one named score. A score returns a number or a map
with `:score` and optional `:feedback`. Higher values win by default. Use
`direction: :minimize` for a loss or cost.

Without `failure_score`, a failed row makes the evaluation ineligible. With a
failure score, the row error stays in the result and the candidate can remain
eligible.

When a pipeline has more than one score, it needs an explicit selector:

```elixir
pipeline
|> Tune.score(:quality, &quality/2, range: {0.0, 1.0})
|> Tune.score(:cost, &cost/2, direction: :minimize, range: {0.0, 10.0})
|> Tune.select(weighted: [quality: 0.8, cost: 0.2])
```

A weighted selector needs an explicit range for every selected score. Raw
scores stay unchanged in each `%Tune.Observation{}`. Tune normalizes only the
selection value.

## Evaluation results

`Tune.evaluate/2` uses test data by default. Pass `:train`, `:validation`, or
`:test` to select another role.

It returns `%Tune.Evaluation{}` with:

- every `%Tune.Observation{}`, including row errors;
- one `%Tune.Score.Summary{}` for each score;
- one higher-is-better selected score;
- eligibility and completion flags;
- call and usage totals;
- a stop reason.

Evaluation is an eager terminal. It consumes the source once and returns a
complete value. Test evaluation is separate from candidate search.

## Generic runners

For a non-program target, give `Tune.new/2` a one-arity or two-arity `:run`
function. A one-arity runner receives the target. A two-arity runner receives
the target and one case input.

```elixir
Tune.new(config, run: fn candidate, batch -> MyBenchmark.run(candidate, batch) end)
```

Tune treats runner values as opaque Elixir terms. This permits Nx tensors,
Axon models, and application structs. The score callback must convert its final
value to a finite Elixir number.
