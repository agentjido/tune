# Programs and evaluation

Use a typed predictor when your application expects named inputs and outputs
from a model. Start with the runnable
[support ticket example](getting_started.md#preview-a-prompt-and-score-a-saved-answer)
to check your prompt and metric with saved answers before you evaluate a live
model.

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
the program code. Make managed calls from the process running the program.
Use evaluation concurrency for parallel calls across cases.

## Data and scores

`Tune.data/2` accepts `:train`, `:validation`, and `:test` data. A value can be
an Enumerable or a zero-arity function that returns an Enumerable. Tune reads
each search split once per run. Each candidate uses the same validation cases.
Set `cases` for an infinite source. An evaluation count limits candidate work
and does not limit data ingestion. With `cases: 0`, Tune leaves the source
unopened.

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
with `:score` and optional `:feedback`. A one-argument function receives the
output. A two-argument scorer receives `(case, output)` for every target.
Set `argument: :prediction` to inspect program steps or usage. Higher values
win by default.
Use `direction: :minimize` for a loss or cost.

Without `failure_score`, a failed row makes the evaluation ineligible. With a
failure score, the row error stays in the result and the candidate can remain
eligible.

Evaluation can report several scores without a selector. Each observation
retains successful scores and records failures in `score_errors`. Search with
several scores requires a selector:

```elixir
pipeline
|> Tune.score(:quality, &quality/2, range: {0.0, 1.0})
|> Tune.score(:cost, &cost/2, direction: :minimize, range: {0.0, 10.0})
|> Tune.select(weighted: [quality: 0.8, cost: 0.2])
```

A weighted selector needs an explicit range for every selected score. Raw
scores stay unchanged in each `%Tune.Observation{}`. Tune normalizes only the
selection value.

## Replay saved responses

Use `Tune.replay/1` with an Enumerable or a data factory. Each row has
`input` and `output`. Add `id` and `expected` when available. JSON string
keys and Elixir atom keys both work.

```elixir
study =
  [%{id: "one", input: %{question: "What is 2 + 2?"}, output: 4, expected: 4}]
  |> Tune.replay()
  |> Tune.score(:exact_match, fn row, output ->
    if row.expected == output, do: 1, else: 0
  end)

{:ok, evaluation} = Tune.evaluate(study)
```

A row for a retrieval judge can put `user_input` and `retrieved_contexts`
inside `input`. Put the saved response in `output` and, if available, the
reference answer in `expected`. The following example reads that row format
from JSONL:

```elixir
rows = fn -> File.stream!("answers.jsonl") |> Stream.map(&JSON.decode!/1) end
{:ok, faithfulness} = Tune.Scores.Faithfulness.new(model: judge_model)
{:ok, precision} = Tune.Scores.ContextPrecision.new(model: judge_model)

pipeline =
  Tune.replay(rows, on_progress: fn event -> send(observer, event) end)
  |> Tune.score(:faithfulness, faithfulness)
  |> Tune.score(:context_precision, precision)
  |> Tune.limit(cases: 500, model_calls: 1_000)

task = Tune.Evaluation.start(my_task_supervisor, pipeline)
{:ok, evaluation} = Task.await(task, :infinity)
```

The replay runner uses the saved answer. Only configured judges make model
calls. Progress events identify each batch's row IDs and statuses. A host can
write these events and the final evaluation to a report or store. To stop a
run, pass a zero-arity `cancel` predicate in the same options as
`on_progress`. Tune checks it while waiting for row workers.

## Compare on a held-out split

```elixir
{:ok, winner} = Tune.tune(study)
{:ok, report} = Tune.compare(study, winner, split: :test)
```

Choose the split explicitly. Tune reads it once and gives both versions the
same ordered cases. Explicit case IDs must be unique non-empty strings. An
omitted ID uses the row's zero-based position as a string.

Use `report.metrics` for paired mean changes and outcome counts. Use
`report.rows[id].metrics` to find regressions, improvements, ties, failed
scores, and unpaired results. A positive delta means that the winner's
numeric score increased. The score direction determines whether that is an
improvement. Means in the comparison use only cases with a score from each
version. Check each metric's `paired_count` against `length(report.case_ids)`.
The underlying evaluations keep all observed scores, errors, model calls,
and token use. Use `Tune.evaluate/1` to score saved responses.

Tune checks both typed targets before running either one. They must have
matching input and output fields. The deadline covers reading the shared
dataset and evaluating both versions.
The baseline runs first. Both passes share one model-call budget. If a limit
stops the comparison, the report keeps the available evidence and sets
`complete?` to false. A case limit defines the size of the shared snapshot.

With a total `model_calls` limit, Tune runs rows one at a time unless you set
`row_calls`. Set `row_calls` to the maximum calls per row to run concurrent
rows under that budget. Concurrent workers reserve the full amount per row.
If the remaining budget is smaller, Tune runs one row with the remaining
calls. When a row reaches its own cap and the shared budget still has calls,
Tune records a row error and continues. When cancellation or the deadline
stops an active row, its observation has status `:interrupted` and records
the stop reason. A row that reached its own timeout is a row error.

A complete comparison can contain failed or unpaired metrics. Require a
valid pair on each critical case before making a release decision.

## Evaluation results

`Tune.evaluate/2` uses test data by default. Pass `:train`, `:validation`, or
`:test` to select another role.
If a data factory or stream raises an exception, evaluation, comparison, and
search return a `Tune.Error.Invalid.Dataset` with the split and original
exception. If a deadline or cancellation stops a streaming evaluation,
the evaluation keeps the rows it already scored.

Tune reads datasets in a worker. A factory should open any process-owned
resources inside the factory so the same worker can read from them.
Invalid saved rows that Tune can read still appear as individual row errors.

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
|> Tune.score(:quality, fn _case, output -> output.quality end)
```

Tune treats runner values as opaque Elixir terms. This permits Nx tensors,
Axon models, and application structs. The score callback must convert its final
value to a finite Elixir number.
