# 04_06 Gate a release on paired evidence

## What you will learn

Compare the same holdout cases in order and apply an application release rule.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/04_eval/04_06_paired_release/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/04_eval/04_06_paired_release/demo.exs
mix test.examples test/examples/04_eval/04_06_paired_release --warnings-as-errors
```

Mean routing accuracy improves across three of three pairs. The release
rule holds the baseline because the critical case regresses.

## Important behavior

Duplicate IDs and expired deadlines prevent target work. A loss of baseline accounting prevents challenger execution.
The release rule also holds the baseline when the critical case is absent or
either version fails to score it.

## Limits

The fixture expresses one local release rule. Tune returns evidence and does not deploy code.

## Core Fit and Gaps

Tune pairs score evidence and retains incomplete results. The host owns release criteria and deployment.

[Chapter index](../README.md) · [Previous](../04_05_background_evaluation/README.md)
