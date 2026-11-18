# 01_12 Vote across classifiers

## What you will learn

Compose compatible classifiers with Tune.Ensemble.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_12_ensemble/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_12_ensemble/demo.exs
mix test.examples test/examples/01_dspy/01_12_ensemble --warnings-as-errors
```

Two of the three classifiers vote for billing, which wins.

## Important behavior

A tie keeps the first vote. A signature mismatch fails before execution. All members use the same call allowance.

## Limits

The ensemble example uses majority voting and equivalent output signatures.

[Chapter index](../README.md) · [Previous](../01_11_support_playbook/README.md)
