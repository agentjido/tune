# 01_03 Bootstrap a grounded QA program

## What you will learn

Learn demonstrations from complete teacher runs over extraction and answering.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_03_bootstrap_qa/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_03_bootstrap_qa/demo.exs
mix test.examples test/examples/01_dspy/01_03_bootstrap_qa --warnings-as-errors
```

Three accepted trajectories supply three demos per predictor. The independent holdout scores 1.0.

Run the [paired comparison](compare_demo.exs) to compare the original and
tuned programs on three separate cases. The [comparison workflow](comparison.ex)
scores answers and citations and prepares the optimized answer prompt.

```sh
MIX_ENV=test mix run examples/01_dspy/01_03_bootstrap_qa/compare_demo.exs
```

Answer accuracy increases from one correct answer to two. Two cases improve
and one regresses. Each version makes six model calls.

## Important behavior

A failed answer excludes its extraction trace as well. A teacher request never includes the current row as a demonstration.

## Limits

The QA program answers only questions in this small offline scenario.

[Chapter index](../README.md) · [Previous](../01_02_labeled_routing/README.md) · [Next](../01_04_search_demos/README.md)
