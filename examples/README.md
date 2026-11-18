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

A bootstrap search learns one demonstration from training data with a
separate teacher model. The example compares the original and the winner on a
different test split. The test has two improvements and one regression. It
prints those counts, the call totals, and the optimized answer prompt.

Every model reply comes from a local `Req.Test` handler. No provider is called.

## Search a finite grid

```sh
mix run examples/generic_grid.exs
```

Tune evaluates each of 16 batch sizes once. It selects batch size 7, then
compares it with the original on two test workloads.

## Tune a plain Elixir value

```sh
mix run examples/generic_genetic.exs
```

This example tunes a map with a generic genetic search. The application runner
measures each candidate. Tune varies the declared integer value, records all
candidate evaluations, selects the best eligible candidate, and reloads its
artifact into a fresh map.

The example uses no LLM and no provider configuration.
