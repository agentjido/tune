# 03_03 Pack a kit under a weight limit

## What you will learn

Use a binary genome and score only feasible kits.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/03_evolution/03_03_pack_kit/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/03_evolution/03_03_pack_kit/demo.exs
mix test.examples test/examples/03_evolution/03_03_pack_kit --warnings-as-errors
```

The selected kit weighs 7 and reaches the known optimum of 11 value units.

## Important behavior

An overweight kit remains visible in history and cannot win.

## Limits

The example uses four items and a known optimum. Genetic search does not certify global optima.

[Chapter index](../README.md) · [Previous](../03_02_evolve_string/README.md) · [Next](../03_04_delivery_route/README.md)
