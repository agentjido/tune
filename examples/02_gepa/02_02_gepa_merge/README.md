# 02_02 Merge complementary repairs

## What you will learn

Use GEPA to combine improvements to the evidence selector and answer writer.

## Read the code

Read [the workflow](../support/multi_hop_qa.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/02_gepa/02_02_gepa_merge/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/02_gepa/02_02_gepa_merge/demo.exs
mix test.examples test/examples/02_gepa/02_02_gepa_merge --warnings-as-errors
```

The report shows parents 1 and 2 from common ancestor 0 and a merge that scores 1.0.

## Important behavior

A merge carries both parent IDs and receives a complete validation report before promotion.

## Limits

The example uses a fixed seed and a program with two named predictor slots.

## Core Fit and Gaps

Tune manages lineage and full validation. The two-stage program defines evidence flow and named components.

[Chapter index](../README.md) · [Previous](../02_01_gepa_qa/README.md) · [Next](../02_03_routing_policy/README.md)
