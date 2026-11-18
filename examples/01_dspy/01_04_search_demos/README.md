# 01_04 Search demonstration sets

## What you will learn

Compare random search and the native categorical TPE strategy on identical training and validation sets.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_04_search_demos/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_04_search_demos/demo.exs
mix test.examples test/examples/01_dspy/01_04_search_demos --warnings-as-errors
```

Both strategies select the fifth invoice as the winning demo. The runner prints validation history and TPE choices after startup.

## Important behavior

Budget exhaustion keeps the last fully validated winner and reports an incomplete search.

## Limits

Tune uses native Elixir TPE for categorical choices. It does not invoke Python Optuna.

## Core Fit and Gaps

Tune reuses a completed validation score when native TPE revisits the same demo set. The trial history shows the revisit without charging another target run.

[Chapter index](../README.md) · [Previous](../01_03_bootstrap_qa/README.md) · [Next](../01_05_neighbor_demos/README.md)
