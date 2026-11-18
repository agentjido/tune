# 04_02 Score grounding and context precision

## What you will learn

Use independent judges for claim support and relevance in retrieval order.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/04_eval/04_02_retrieval/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/04_eval/04_02_retrieval/demo.exs
mix test.examples test/examples/04_eval/04_02_retrieval --warnings-as-errors
```

The answer has faithfulness 1.0 and context precision 0.5833. Judging uses five calls.

## Important behavior

A failed ranking judge counts as an attempted call and preserves the faithfulness score.

## Limits

Scripted judge output validates accounting and scoring behavior. It does not measure judge agreement.

## Core Fit and Gaps

The evaluator reports independent scores and attempted judge calls. The application owns the corpus, retrieval ranking, and the decision to act on a judge score.

[Chapter index](../README.md) · [Previous](../04_01_saved_replay/README.md) · [Next](../04_03_streamed_csv/README.md)
