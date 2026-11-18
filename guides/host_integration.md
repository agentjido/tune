# Host integration

Tune does not own an agent runtime. A Jido agent or another host can expose its
normal run function to Tune.

```elixir
study =
  Tune.new(agent_config, run: fn config, task -> MyAgent.run(config, task) end)
  |> Tune.data(validation: validation_tasks)
  |> Tune.score(:correctness, &MyScores.correctness/2)
  |> Tune.vary(system_prompt: Tune.Space.Text.new(prompt_candidates))
  |> Tune.search(:genetic)
  |> Tune.limit(evaluations: 100)
```

The host keeps control of tools, authorization, sessions, memory, lifecycle,
and side effects. Tune receives only the target, case input, output, and score
evidence that the application gives it.

## Hosted structured inference

A host can run a typed predictor or composed program directly with
`Tune.Runtime.run/3`. Pass the application model configuration and any
execution limits.

~~~elixir
{:ok, prediction} =
  Tune.Runtime.run(program, inputs, model: model, max_model_calls: 2)

prediction.output
~~~

A host can keep its own inference path for a structured Tune predictor.

```elixir
{:ok, prepared} = Tune.Predictor.prepare(predictor, inputs, model)

with :ok <- MyHost.authorize(prepared),
     {:ok, response} <- MyHost.generate(prepared.context, output: prepared.output) do
  Tune.Predictor.finish(prepared, response)
end
```

`prepare/3` is pure. It renders a ReqLLM context and an output descriptor. It
holds no credentials. `finish/2` parses and validates one supplied response. It
makes no model request.

The host must keep the same output contract as direct Tune execution. It must
disable JSON repair and use strict output validation for structured output.

Repair or extraction is an explicit program step. It is not hidden in an
adapter. A host denial does not create a Tune step.

## Effect accounting

Tune can count model calls that pass through Tune programs and Tune judge
scores. Tune cannot inspect hidden calls in an opaque application runner. The
host must enforce its own call, tool, time, and cost limits for those effects.

If a runner returns `%Tune.Prediction{}`, Tune uses its call and usage fields.
Other runner outputs remain opaque.

Tune has no Jido dependency. A Jido integration must test the real Jido
inference path and its controls.
