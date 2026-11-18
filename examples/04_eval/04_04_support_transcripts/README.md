# 04_04 Evaluate multi-turn support transcripts

## What you will learn

Use ordered transcript turns for separate escalation and resolution scores.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/04_eval/04_04_support_transcripts/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/04_eval/04_04_support_transcripts/demo.exs
mix test.examples test/examples/04_eval/04_04_support_transcripts --warnings-as-errors
```

Both transcripts show escalation. One has a final resolution and one has a missing-answer error.

## Important behavior

A missing final answer affects resolution only.

## Limits

The application checks explicit escalation and resolution text. This is a deterministic policy check.

[Chapter index](../README.md) · [Previous](../04_03_streamed_csv/README.md) · [Next](../04_05_background_evaluation/README.md)
