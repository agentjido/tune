# 01_07 Optimize instructions and demonstrations

## What you will learn

Use MIPROv2 to search instruction and demonstration choices and validate promising combinations.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_07_joint_search/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_07_joint_search/demo.exs
mix test.examples test/examples/01_dspy/01_07_joint_search --warnings-as-errors
```

The program selects "Be exact." with one demonstration and scores 1.0 on the full validation split.

## Important behavior

A memorized minibatch winner loses on full validation. Target, teacher, and proposal calls share one limit.

## Limits

The fixture tests selection and accounting with a small categorical space.

## Core Fit and Gaps

Named roles let the host set different model options. The shared ceiling counts logical calls across those roles. The example does not estimate provider cost.

[Chapter index](../README.md) · [Previous](../01_06_rewrite_instructions/README.md) · [Next](../01_08_infer_rules/README.md)
