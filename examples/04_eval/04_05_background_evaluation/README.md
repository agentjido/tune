# 04_05 Supervise evaluation in the background

## What you will learn

Start evaluation under a host Task.Supervisor and publish application progress and reports.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/04_eval/04_05_background_evaluation/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/04_eval/04_05_background_evaluation/demo.exs
mix test.examples test/examples/04_eval/04_05_background_evaluation --warnings-as-errors
```

Progress arrives for both rows and the final routing score is 1.0.

## Important behavior

Cancellation returns completed rows and worker error evidence. The active worker terminates.

## Limits

The host owns the supervisor, reporting, and any durable job tracking.

## Core Fit and Gaps

Tune reports row progress and a final evaluation. The host owns scheduling, notification, and durable results.

[Chapter index](../README.md) · [Previous](../04_04_support_transcripts/README.md) · [Next](../04_06_paired_release/README.md)
