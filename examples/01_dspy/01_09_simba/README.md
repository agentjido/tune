# 01_09 Reduce inconsistent routing

## What you will learn

Use SIMBA to add a successful demonstration or instruction advice.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_09_simba/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_09_simba/demo.exs
mix test.examples test/examples/01_dspy/01_09_simba --warnings-as-errors
```

Both paths reach 1.0. The demo path adds a labeled case and the rule path adds instruction text.

## Important behavior

Failed trajectories produce neither kind of update.

## Limits

The scripted tickets isolate the two update paths.

## Core Fit and Gaps

Tune gates updates on observed trajectories and retains validation evidence. The host owns any decision to apply an artifact.

[Chapter index](../README.md) · [Previous](../01_08_infer_rules/README.md) · [Next](../01_10_avatar_urgency/README.md)
