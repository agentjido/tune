# 04_01 Replay saved JSONL answers

## What you will learn

Use `Tune.replay/1` to score saved answers from JSONL. Each row has an
`input` and an `output`. The scorer receives the case and the saved output.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/04_eval/04_01_saved_replay/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/04_eval/04_01_saved_replay/demo.exs
mix test.examples test/examples/04_eval/04_01_saved_replay --warnings-as-errors
```

```text
Replayed ["paris", "rome"]
Target calls 0
```

## Important behavior

A missing `output` produces a row error. The factory opens the file once.

## Limits

The local fixture contains two single-turn answers. The example scores answer length.

## Fixtures

- [saved.jsonl](fixtures/saved.jsonl)

[Chapter index](../README.md) · [Next](../04_02_retrieval/README.md)
