# 01_02 Route tickets from labeled examples

## What you will learn

Use LabeledFewShot with seeded sampling on a Banking77-style ticket set.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_02_labeled_routing/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_02_labeled_routing/demo.exs
mix test.examples test/examples/01_dspy/01_02_labeled_routing --warnings-as-errors
```

The search learns four demonstrations, makes zero model calls, and scores 1.0 on the separate holdout.

## Important behavior

Duplicate training inputs produce no extra demonstrations. The same seed keeps the same sample.

## Limits

The Banking77-style fixture contains three categories and scripted predictions.

[Chapter index](../README.md) · [Previous](../01_01_extract_ticket/README.md) · [Next](../01_03_bootstrap_qa/README.md)
