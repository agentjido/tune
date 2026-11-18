# 01_10 Improve an urgency predictor

## What you will learn

Give Avatar contrasting good and bad traces and name one predictor to rewrite.

## Read the code

Read [the workflow](../support/support_guide.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_10_avatar_urgency/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_10_avatar_urgency/demo.exs
mix test.examples test/examples/01_dspy/01_10_avatar_urgency --warnings-as-errors
```

Only the urgency instruction changes. The new instruction recognizes blocked payments and scores 1.0.

## Important behavior

If the training set does not have both kinds of evidence, the validated program remains in place.

## Limits

The example does not learn the full support classification policy.

## Core Fit and Gaps

Trace evidence and named predictors keep the change local. The application supplies positive and negative criteria through the declared score thresholds.

[Chapter index](../README.md) · [Previous](../01_09_simba/README.md) · [Next](../01_11_support_playbook/README.md)
