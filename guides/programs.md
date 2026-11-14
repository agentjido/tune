# Programs, predictors, and evaluation

## Signatures and predictors

A signature declares ordered, typed input and output fields and task
instructions. Field schemas are Zoi schemas restricted to JSON values:
strings, integers, floats, numbers, booleans, null, string enums, scalar
literals, arrays, string-keyed objects and records, and unions of those.
Declared fields are required; use a nullable schema for optional values.

```elixir
{:ok, predictor} =
  Tune.Predictor.new(
    signature: [
      instructions: "Classify the support ticket.",
      inputs: [ticket: Zoi.string(description: "Customer message")],
      outputs: [label: Zoi.enum(["billing", "bug", "other"]), confidence: Zoi.float()]
    ]
  )
```

Names are normalized to strings once. Inputs may use the declared atom or
string keys; values and outputs are string-keyed maps.

## Model configuration

A run uses one explicit, fixed model configuration per role: a ReqLLM model,
a prompt adapter, adapter options, and ReqLLM request options.

```elixir
{:ok, model} =
  Tune.ModelConfig.new(
    model: "openai:gpt-4o-mini",
    adapter: Tune.Adapter.JSON,
    adapter_options: [mode: :structured],
    request_options: [temperature: 0.0]
  )
```

Options that would replace the output contract, change the prompt, add tools,
stream, or repair output (`:output`, `:output_repair`, `:output_validation`,
`:system_prompt`, `:tools`, `:tool_choice`, `:stream`, `json_repair: true`) are
rejected. Every managed request sends `json_repair: false`; structured output
uses strict validation, and any ReqLLM repair or type coercion is rejected.

## Adapters

`Adapter.Chat`, `Adapter.JSON` (`mode: :text | :structured`), and
`Adapter.XML` render and parse only. They never call a model, retry, repair,
or fall back to another format. All three produce the same validated output
map. Compare formats by measured score, parse success, and tokens.

## Inspecting and hosting a request

`Predictor.prepare/3` validates inputs and renders a `Prepared` value with
the ReqLLM context and output descriptor, without credentials or request
options. `Predictor.finish/2` checks a `ReqLLM.Response` (no error or
refusal, finish reason `:stop`, or `:tool_calls` for structured output) and
returns a validated `Step`. See [Host integration](host_integration.md).

## Composition

A composite program is an application struct implementing the
`Tune` behaviour. Control flow is ordinary Elixir:

```elixir
def call(_program, inputs, execution) do
  with {:ok, %{"facts" => facts}, execution} <- Execution.predict(execution, "extract", inputs),
       {:ok, lessons} <- Execution.value(execution, "lessons") |> wrap(execution) do
    Execution.predict(execution, "answer", %{
      "question" => inputs["question"],
      "facts" => facts,
      "guidance" => Enum.join(lessons, "\n")
    })
  end
end
```

`Tune.run/3` returns a `Result` with the validated output, every
step in call order, failed calls, and attempted calls per role. A failure
after the run starts returns `Error.Execution.Failed` with the original cause
and the partial result. Runs enforce `:max_model_calls` (optional), a step
limit (default 32), and a cooperative deadline (default 60 s) that caps each
request's `:total_timeout`. Work in application callbacks outside
`Execution` is not managed.

## Evaluation

```elixir
{:ok, evaluation} =
  Tune.evaluate(program, rows,
    model: model,
    metric: fn example, result -> if result.output["label"] == example.labels["label"], do: 1, else: 0 end
  )
```

A metric returns a finite number or `%{score: number, feedback: text}`.
Higher is better; there is no range. Failed rows are kept. Without
`:failure_score` a failed row makes the evaluation ineligible and
`selection_score` is `nil`; with it, the score is included in the mean.
Labels are passed only to the metric. Rows have a hard timeout; under a call
limit, a killed row reserves its allowance and no further rows start.
Optimization never accepts test data; run final test evaluation separately.
