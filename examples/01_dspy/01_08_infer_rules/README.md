# 01_08 Infer escalation rules

## What you will learn

Learn escalation rules from accepted examples and validate their effect.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_08_infer_rules/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_08_infer_rules/demo.exs
mix test.examples test/examples/01_dspy/01_08_infer_rules --warnings-as-errors
```

The selected rule escalates unrecognized charges and scores 1.0 on the holdout.

## Important behavior

A harmful rule loses to the bootstrapped incumbent.

## Limits

The example uses a small labeled support policy. It does not define a real escalation policy.

## Core Fit and Gaps

Rules are inspectable learned instructions. The application defines which regressions matter and supplies the held-out cases to measure them.

[Chapter index](../README.md) · [Previous](../01_07_joint_search/README.md) · [Next](../01_09_simba/README.md)
