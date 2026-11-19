# Host Integration

Use this guide when your application already owns an agent or inference loop
and you want Tune to evaluate it, run typed predictors inside it, or validate
replies that the host requests itself.

Tune never takes over the host's runtime. The host keeps its tools,
credentials, authorization, sessions, memory, and side effects. Tune sees only
the target, the case input, the output, and the evidence the host returns.

## Evaluate the host's runner

Pass the function the host already calls to `Tune.new/2` with `run:`. The
runner receives the target and one case input. Here the host is a support desk
that looks up an order with its own tool and drafts a reply. The target is the
host's configuration, so a search can later vary it.

```elixir
defmodule SupportDesk do
  @moduledoc "A host-owned support flow with its own tool and reply policy."

  def answer(config, %{order_id: order_id}) do
    order = lookup_order(order_id)
    {:ok, %{"status" => order.status, "reply" => "#{config.greeting} Your order is #{order.status}."}}
  end

  defp lookup_order("A-100"), do: %{status: "shipped"}
  defp lookup_order(_order_id), do: %{status: "processing"}
end

{:ok, evaluation} =
  %{greeting: "Hi!"}
  |> Tune.new(run: fn config, input -> SupportDesk.answer(config, input) end)
  |> Tune.data(
    test: [
      %{id: "shipped", input: %{order_id: "A-100"}, expected: %{status: "shipped"}},
      %{id: "pending", input: %{order_id: "B-200"}, expected: %{status: "processing"}}
    ]
  )
  |> Tune.score(:status, fn tune_case, output ->
    if output["status"] == tune_case.expected.status, do: 1, else: 0
  end)
  |> Tune.evaluate()

{evaluation.selected_score, evaluation.calls}
```

The evaluation returns `{1.0, %{}}`. The score is the mean over both cases.
`calls` is empty because the runner made no call that Tune can see.

A runner can return any of these shapes:

| Runner returns | Tune records |
| --- | --- |
| `output` or `{:ok, output}` | The output. No call evidence. |
| `{:ok, output, metadata}` with a map | The output and the metadata on the observation. |
| `{:ok, output, %Tune.Prediction{}}` | The output, plus the prediction's calls and token use. |
| `{:error, reason}` | A failed case with that error. |
| `{:error, reason, %Tune.Prediction{}}` | A failed case that keeps the partial calls. |

A bare `%Tune.Prediction{}` is treated as plain output. Wrap it in
`{:ok, prediction.output, prediction}` to pass its call evidence.

## Script the model replies

The rest of this guide calls a model. This module stands in for the provider.
It serves fixed OpenAI-compatible replies to ReqLLM through an in-process Plug,
so the guide runs offline. Add `{:plug, "~> 1.20 and >= 1.20.4"}` to your
project's dependencies. In your application, pass a real model spec and let
the host supply the credentials.

```elixir
defmodule Scripted do
  @moduledoc "Serves scripted OpenAI-compatible replies to ReqLLM through an in-process Plug."

  def model, do: %{provider: :openai, id: "gpt-4-turbo", extra: %{wire: %{protocol: "openai_chat"}}}

  def options(replies) do
    {:ok, queue} = Agent.start_link(fn -> replies end)

    plug = fn conn ->
      reply = Agent.get_and_update(queue, fn [next | rest] -> {next, rest}; [] -> {nil, []} end)
      respond(conn, reply)
    end

    [api_key: "scripted", req_http_options: [plug: plug], max_retries: 0]
  end

  def chat(fields) do
    Enum.map_join(fields, "\n\n", fn {name, value} -> "[[ ## #{name} ## ]]\n#{value}" end) <>
      "\n\n[[ ## completed ## ]]"
  end

  defp respond(conn, nil), do: send_json(conn, 500, %{error: %{message: "no scripted reply left"}})

  defp respond(conn, text) do
    send_json(conn, 200, %{
      id: "scripted",
      model: "gpt-4-turbo",
      choices: [%{message: %{role: "assistant", content: text}, finish_reason: "stop"}],
      usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    })
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end
end
```

## Run a predictor inside the host

`Tune.Runtime.run/3` runs a typed predictor or a composed program on one
input. Pass the host's model configuration as `:model`. Bound the run with
`:max_model_calls`, `:max_steps`, or `:timeout` in milliseconds.

```elixir
{:ok, predictor} =
  Tune.Predictor.new(
    signature: [
      instructions: "Classify the customer message.",
      inputs: [message: Zoi.string()],
      outputs: [intent: Zoi.enum(["order_status", "refund", "other"])]
    ]
  )

model = [
  model: Scripted.model(),
  adapter: Tune.Adapter.Chat,
  request_options: Scripted.options([Scripted.chat(intent: "order_status")])
]

{:ok, prediction} =
  Tune.Runtime.run(predictor, %{message: "Where is my parcel?"},
    model: model,
    max_model_calls: 2
  )

{prediction.output, prediction.calls, Tune.Prediction.token_totals(prediction)}
```

```text
{%{"intent" => "order_status"}, %{target: 1},
 %{input: 10, output: 5, total: 15}}
```

The prediction counts one target call. `Tune.Prediction.token_totals/1` sums
the token use that the provider reported in its responses. When the
host runs this inside a Tune runner, return
`{:ok, prediction.output, prediction}` so the evaluation counts the call.

## Send the request yourself

Some hosts must authorize, log, or route every model request through their own
inference path. Split the call in two:

1. `Tune.Predictor.prepare/3` validates the inputs and renders a
   `Tune.Prepared` request. It takes a `Tune.ModelConfig` struct.
2. The host sends `prepared.context` with `prepared.output` through ReqLLM.
3. `Tune.Predictor.finish/2` parses and validates the response and returns a
   `Tune.Step`.

`prepare/3` and `finish/2` make no model request. The prepared struct holds no
model, credentials, or request options.

```elixir
defmodule Gateway do
  @moduledoc "The host's own authorization and inference path."

  def generate(prepared, config, :allowed) do
    ReqLLM.generate_text(
      config.model,
      prepared.context,
      Tune.ModelConfig.request_options(config, prepared.output)
    )
  end

  def generate(_prepared, _config, :denied), do: {:error, :denied_by_host}
end

{:ok, config} =
  Tune.ModelConfig.new(
    model: Scripted.model(),
    adapter: Tune.Adapter.Chat,
    request_options: Scripted.options([Scripted.chat(intent: "refund")])
  )

{:ok, prepared} = Tune.Predictor.prepare(predictor, %{message: "I want my money back"}, config)

with {:ok, response} <- Gateway.generate(prepared, config, :allowed),
     {:ok, step} <- Tune.Predictor.finish(prepared, response) do
  step.outputs
end
```

```text
%{"intent" => "refund"}
```

`Tune.ModelConfig.request_options/3` returns the host's request options with
the prepared output descriptor, `json_repair: false`, and strict validation for
structured output. Use it so that the host request keeps the same contract as
`Tune.Runtime.run/3`.

A denial stops before any request. It produces no step, so nothing reaches
`finish/2`:

```elixir
Gateway.generate(prepared, config, :denied)
```

```text
{:error, :denied_by_host}
```

## Output validation contract

`Tune.Predictor.finish/2` accepts a response only when all of these hold:

- The response has no error and no refusal.
- The finish reason is `:stop`, or `:tool_calls` for structured output.
- Structured output is strictly valid, and ReqLLM made no repairs.
- The adapter parses the reply, and every output field passes its Zoi schema.

Each failure returns an error and no step. A truncated reply is rejected even
when the host builds the response itself:

```elixir
truncated = %ReqLLM.Response{
  id: "host-1",
  model: "gpt-4-turbo",
  context: ReqLLM.Context.new(),
  message: ReqLLM.Context.assistant("[[ ## intent ## ]]\nref"),
  finish_reason: :length
}

{:error, error} = Tune.Predictor.finish(prepared, truncated)
{error.__struct__, error.reason}
```

```text
{Tune.Error.Output.Rejected, :finish_reason}
```

Tune does not repair, retry, or switch adapters. Repair or extraction is an
explicit program step. ReqLLM owns transport retries. `Tune.ModelConfig.new/1`
rejects request options that would change the contract, such as `:output`,
`:tools`, `:stream`, or `json_repair: true`.

## Count model calls and effects

Tune counts the model calls that pass through Tune: predictors and programs
run as targets, `Tune.Runtime.run/3`, and judge scores. It also counts calls
that a runner reports in a `%Tune.Prediction{}`. Those counts appear in
`evaluation.calls` and `evaluation.usage`, and `Tune.limit/2` with
`model_calls:` stops work when the budget runs out.

Tune cannot see calls hidden inside an opaque runner. A runner that returns
plain output reports no calls, so a `model_calls:` limit cannot stop it. The
calls from the `prepare/3` and `finish/2` path are also the host's to count.

The host tracks and limits its own effects:

- Model calls Tune cannot see.
- Tool calls, writes, messages, and other side effects.
- Cost, rate limits, and wall-clock budgets outside the Tune run.

Tune has no Jido dependency. A Jido host passes its normal run function as the
runner and keeps its own inference controls at that boundary.

## Next steps

- [Typed Predictors](api/typed-predictors.livemd) shows the prompt formats and
  validation errors in detail.
- [Programs](programs.md) composes predictors into multi-step programs.
- [Deploy a Router](integration/deploy-a-router.livemd) loads a tuned artifact
  into a running service.
