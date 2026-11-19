# Programs

A Tune program is an application struct that implements `Tune.Program`. It
names the predictors and values that a search may change. Its control flow is
ordinary Elixir code. This guide builds a two-step support program, runs it,
reads the recorded steps, and updates one predictor the way a search does.

Every model call in this guide goes to a scripted transport, so the code runs
offline with no credentials. Add `{:plug, "~> 1.20 and >= 1.20.4"}` to your
project's dependencies to run the scripted examples.

## Define the program

The program answers a refund question in two steps. `extract` picks the policy
facts that matter. `answer` writes the reply from those facts.

```elixir
defmodule RefundAnswer do
  @moduledoc "Answers a refund question from the facts in a policy."

  @behaviour Tune.Program

  alias Tune.Execution

  defstruct [:extract, :answer]

  def new do
    {:ok, extract} =
      Tune.Predictor.new(
        signature: [
          instructions: "List the policy facts that answer the question.",
          inputs: [question: Zoi.string(), policy: Zoi.string()],
          outputs: [facts: Zoi.array(Zoi.string())]
        ]
      )

    {:ok, answer} =
      Tune.Predictor.new(
        signature: [
          instructions: "Answer the customer using only the facts.",
          inputs: [question: Zoi.string(), facts: Zoi.array(Zoi.string())],
          outputs: [answer: Zoi.string()]
        ]
      )

    %__MODULE__{extract: extract, answer: answer}
  end

  @impl true
  def signature(_program) do
    {:ok, signature} =
      Tune.Signature.new(
        inputs: [question: Zoi.string(), policy: Zoi.string()],
        outputs: [answer: Zoi.string()]
      )

    signature
  end

  @impl true
  def parameters(program), do: %{"extract" => program.extract, "answer" => program.answer}

  @impl true
  def put_parameters(program, parameters),
    do: %{program | extract: parameters["extract"], answer: parameters["answer"]}

  @impl true
  def call(_program, inputs, execution) do
    with {:ok, %{"facts" => facts}, execution} <-
           Execution.predict(execution, "extract", inputs) do
      Execution.predict(execution, "answer", %{
        "question" => inputs["question"],
        "facts" => facts
      })
    end
  end
end
```

Each callback has one job:

- `signature/1` declares the program's own inputs and outputs. Tune validates
  inputs before `call/3` and the final output after it.
- `parameters/1` returns every tunable part under a stable string name. A
  value is a `Tune.Predictor` or a `Tune.Parameter`.
- `put_parameters/2` puts a full map of parameters back into the struct.
- `call/3` runs the steps. `Tune.Execution.predict/3` calls the predictor by
  name and returns `{:ok, outputs, execution}` or `{:error, reason, execution}`.
  Return the last `execution` you received.

Inputs reach `call/3` with string keys. Validated outputs are string-keyed
maps, so the `extract` result matches `%{"facts" => facts}`.

## Script the model replies

This module stands in for the provider. It serves fixed OpenAI-compatible
replies to ReqLLM through an in-process Plug, so the guide runs offline. In
your application, pass a real model spec and let the host supply the
credentials.

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

## Run the program

`Tune.Runtime.run/3` runs one input and returns a `%Tune.Prediction{}`. The
`:model` option is required. It holds the model spec, the adapter, and the
ReqLLM request options.

```elixir
replies = [
  Scripted.chat(facts: ~s(["Refunds are allowed within 30 days.", "Refunds go to the original card."])),
  Scripted.chat(answer: "Yes. You can get a refund within 30 days, paid back to your original card.")
]

model = [
  model: Scripted.model(),
  adapter: Tune.Adapter.Chat,
  request_options: Scripted.options(replies)
]

ticket = %{
  question: "Can I get a refund after two weeks?",
  policy: "Refunds are allowed within 30 days of purchase. Refunds go to the original card."
}

{:ok, prediction} = Tune.Runtime.run(RefundAnswer.new(), ticket, model: model)

IO.inspect(prediction.output)
IO.inspect(prediction.calls)

for step <- prediction.steps do
  IO.inspect({step.name, step.role, step.outputs})
end
```

```text
%{
  "answer" => "Yes. You can get a refund within 30 days, paid back to your original card."
}
%{target: 2}
{"extract", :target,
 %{
   "facts" => ["Refunds are allowed within 30 days.",
    "Refunds go to the original card."]
 }}
{"answer", :target,
 %{
   "answer" => "Yes. You can get a refund within 30 days, paid back to your original card."
 }}
```

`prediction.steps` lists each completed predictor call in order. A
`%Tune.Step{}` keeps its name, role, signature, actual inputs, validated
outputs, and the unchanged `ReqLLM.Response`. `prediction.calls` counts the
attempted model calls for each role.

## Where model configuration comes from

The program struct holds no model, adapter, or credentials. They arrive at
run time:

- `Tune.Runtime.run/3` takes them as `:model`, and optionally `:teacher` and
  `:proposal`.
- `Tune.new/2` takes the same keys for evaluation and search.

Each value is a keyword list or a `Tune.ModelConfig` with `:model`,
`:adapter`, `:adapter_options`, and `:request_options`. Steps run with the
`:target` configuration unless a search runs them as `:teacher`. The target
model and adapter stay fixed for a whole search. Keep API keys in the host's
`request_options` or ReqLLM configuration. Search results and artifacts
describe a model only by its name, adapter, and adapter options.

Bound one run with `:max_model_calls`, `:max_steps` (default 32), and
`:timeout` in milliseconds (default 60,000). Make every
`Tune.Execution.predict/3` call from the process that runs `call/3`. For
parallel work, run several cases with evaluation concurrency.

## Handle a failed step

When a step fails, `Tune.Runtime.run/3` returns `Tune.Error.Execution.Failed`.
The error names the failed step and keeps the partial prediction. Here the
script holds only one reply, so the `answer` call fails.

```elixir
model = [
  model: Scripted.model(),
  adapter: Tune.Adapter.Chat,
  request_options: Scripted.options([Scripted.chat(facts: ~s(["Refunds are allowed within 30 days."]))])
]

{:error, error} = Tune.Runtime.run(RefundAnswer.new(), ticket, model: model)

IO.inspect(error.step)
IO.inspect(Enum.map(error.result.steps, & &1.name))
IO.inspect(error.result.calls)
```

```text
"answer"
["extract"]
%{target: 2}
```

The failed call still counts. Tune counts each call before dispatch.

## Update a declared parameter

A search changes a program only through its declared parameters. It builds a
new predictor, then calls `Tune.Program.replace_parameters/2`. You can do the
same by hand, and preview the new prompt with `Tune.preview/2`. A preview
makes no model call. For a composed program, pass the predictor name with its
inputs.

```elixir
program = RefundAnswer.new()

{:ok, answer} =
  Tune.Predictor.put_instructions(program.answer, "Answer in one sentence. Use only the facts.")

{:ok, updated} = Tune.Program.replace_parameters(program, %{"answer" => answer})

{:ok, prepared} =
  updated
  |> Tune.new(model: [model: Scripted.model(), adapter: Tune.Adapter.Chat])
  |> Tune.preview({"answer", %{question: "Can I get a refund?", facts: ["Refunds are allowed within 30 days."]}})

IO.inspect(prepared.signature.instructions)
IO.inspect(Enum.map(prepared.context.messages, & &1.role))
```

```text
"Answer in one sentence. Use only the facts."
[:system, :user]
```

A replacement must keep its kind and its fields. Instructions and
demonstrations can change. Field names and schemas cannot.

```elixir
{:ok, other} =
  Tune.Predictor.new(signature: [inputs: [q: Zoi.string()], outputs: [answer: Zoi.string()]])

{:error, error} = Tune.Program.replace_parameters(program, %{"answer" => other})
IO.puts(Exception.message(error))
```

```text
predictor "answer" changes its declared fields
```

## Declare a tunable value

Use `Tune.Parameter` for a JSON value that the program reads, such as a list
of lessons or a routing policy. Its Zoi schema stays in code, and every new
value is checked against it.

```elixir
{:ok, lessons} =
  Tune.Parameter.new(
    schema: Zoi.array(Zoi.string()),
    value: [],
    description: "Lessons learned from earlier tickets"
  )

{:ok, lessons} = Tune.Parameter.put_value(lessons, ["Quote the refund window."])
IO.inspect(lessons.value)
IO.inspect(match?({:error, _}, Tune.Parameter.put_value(lessons, [1])))
```

```text
["Quote the refund window."]
true
```

Return the parameter from `parameters/1` under a name such as `"lessons"`.
Inside `call/3`, read it with `Tune.Execution.value(execution, "lessons")` and
pass it to a predictor as an ordinary input. Strategies such as `:playbook`
and `:anything` change only the named value.

## Next steps

- [Search API](optimizers.md) lists the strategies that update these parameters.
- [Artifacts](artifacts.md) saves the learned parameters and loads them into fresh code.
- [Typed predictors](api/typed-predictors.livemd) covers signatures, adapters, and previews in more depth.
