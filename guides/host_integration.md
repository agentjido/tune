# Host integration

A host such as a Jido agent can keep its own inference path and controls.

```elixir
{:ok, prepared} = Tune.Predictor.prepare(predictor, inputs, model)

with :ok <- MyHost.authorize(prepared),
     {:ok, response} <- MyHost.generate(prepared.context, output: prepared.output) do
  Tune.Predictor.finish(prepared, response)
end
```

- `prepare/3` is pure. It renders the ReqLLM context and output descriptor
  and holds no model, credentials, or request options.
- The host chooses its fixed model configuration, applies guards, budgets,
  and telemetry, and executes the request once. It should pass
  `json_repair: false` and, for structured output, `output_validation: :strict`
  to keep the same output contract as direct runs.
- `finish/2` makes no model request. A host denial never produces a step.
- Repair or extraction is another explicit program step, never hidden in an
  adapter.
- Host instructions, authorization, sessions, tools, and lifecycle are not
  learnable parameters.

`Tune.run/3` is a thin direct path through `ReqLLM.generate_text/3`.
It is not evidence that a host's controls were applied. This package has no
Jido dependency; actual Jido integration is separate work that must exercise
Jido's own inference path.
