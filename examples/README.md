# Tune examples

Run each command from the `tune` directory.

## Inspect structured prompts

```sh
mix run examples/inspect_prompts.exs
```

This example defines one typed predictor. It calls `Tune.preview/2` for the
Chat, JSON, and XML adapters. It prints the exact messages that ReqLLM would
receive. It makes no model request.

## Tune a structured LLM program

```sh
MIX_ENV=test mix run examples/lazy_structured_prompt.exs
```

This example uses a two-step grounded QA program. The `extract` step selects
facts. The `answer` step uses the facts and cites their source identifiers.

The pipeline has separate training and validation data. It has an answer score
and a citation score. An explicit weighted selector combines the scores. A
bootstrap search learns one demonstration with a separate teacher model.

Every model reply comes from a local `Req.Test` handler. No provider is called.
The target handler returns a correct citation but an incorrect baseline answer.
The selected score changes from `0.2` to `1.0`. The script then prints the
optimized answer prompt and its learned demonstration.

## Tune a plain Elixir value

```sh
mix run examples/generic_genetic.exs
```

This example tunes a map with a generic genetic search. The application runner
measures each candidate. Tune varies the declared integer value, records all
candidate evaluations, selects the best eligible candidate, and reloads its
artifact into a fresh map.

The example uses no LLM and no provider configuration.
