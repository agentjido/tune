# 01_06 Rewrite named instructions

## What you will learn

Run SignatureOptimizer and COPRO on the same grounded QA program.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_06_rewrite_instructions/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_06_rewrite_instructions/demo.exs
mix test.examples test/examples/01_dspy/01_06_rewrite_instructions --warnings-as-errors
```

Both retain "Cite the passage id and answer." and score 1.0 on the holdout.

## Important behavior

A named search leaves the other predictor alone, and a tied candidate leaves the earlier winner in place.

## Limits

The candidate instructions come from a scripted proposal model.

[Chapter index](../README.md) · [Previous](../01_05_neighbor_demos/README.md) · [Next](../01_07_joint_search/README.md)
