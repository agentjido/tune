# 04_03 Evaluate streamed CSV

## What you will learn

Keep parsing in the application and report exact match, abstention, and minimized cost.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/04_eval/04_03_streamed_csv/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/04_eval/04_03_streamed_csv/demo.exs
mix test.examples test/examples/04_eval/04_03_streamed_csv --warnings-as-errors
```

Three of four rows contribute scores. Exact-match accuracy becomes 0.5 when the parse failure receives its explicit selection penalty.

## Important behavior

The malformed row retains its parse evidence. Raw summaries and coverage still reflect only actual scores.

## Limits

The fixture has unquoted columns. Use an application CSV parser for quoted fields and multiline records.

## Fixtures

- [support.csv](fixtures/support.csv)

[Chapter index](../README.md) · [Previous](../04_02_retrieval/README.md) · [Next](../04_04_support_transcripts/README.md)
