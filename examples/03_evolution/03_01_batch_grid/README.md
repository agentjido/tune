# 03_01 Search batch and worker settings

## What you will learn

Enumerate finite integer and choice spaces and compare the winner with the original on fresh workloads.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/03_evolution/03_01_batch_grid/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/03_evolution/03_01_batch_grid/demo.exs
mix test.examples test/examples/03_evolution/03_01_batch_grid --warnings-as-errors
```

Tune evaluates 48 combinations and selects batch size 7 with 2 workers. The holdout score improves by 8.0.

## Important behavior

The validation factory runs once, history order stays stable, and an evaluation cap stops at the exact candidate count.

## Limits

The runner uses a synthetic throughput model. It does not benchmark machines.

[Chapter index](../README.md) · [Next](../03_02_evolve_string/README.md)
