# 01_11 Learn a bounded support playbook

## What you will learn

Pass a selected lesson into normal application code as an input to the urgency predictor.

## Read the code

Read [the workflow](../support/support_guide.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_11_support_playbook/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_11_support_playbook/demo.exs
mix test.examples test/examples/01_dspy/01_11_support_playbook --warnings-as-errors
```

One short lesson about blocked payments raises validation accuracy to 1.0.

## Important behavior

Too many or invalid lessons do not proceed to validation. A valid but harmful lesson loses on validation.

## Limits

The application consumes a small portable text list. It does not store operational knowledge.

## Core Fit and Gaps

Tune bounds learned lesson strings and persists the accepted list. The application controls where the list enters its prompt.

[Chapter index](../README.md) · [Previous](../01_10_avatar_urgency/README.md) · [Next](../01_12_ensemble/README.md)
