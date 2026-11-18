# 02_03 Tune a typed routing policy

## What you will learn

Use Optimize.Anything to revise one structured risk policy that application code reads.

## Read the code

Read [the workflow](../../support/policy.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/02_gepa/02_03_routing_policy/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/02_gepa/02_03_routing_policy/demo.exs
mix test.examples test/examples/02_gepa/02_03_routing_policy --warnings-as-errors
```

The policy reloads with a review threshold of 0.6 and scores 1.0.

## Important behavior

A string in the threshold field fails schema validation and receives no candidate evaluation. The standard queue remains fixed.

## Limits

The fixture proves artifact portability for one typed value. It does not measure production risk.

## Core Fit and Gaps

Tune validates the declared value and restores it through an artifact. The application owns how the threshold affects routing.

[Chapter index](../README.md) · [Previous](../02_02_gepa_merge/README.md)
