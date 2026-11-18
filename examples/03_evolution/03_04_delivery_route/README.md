# 03_04 Minimize delivery distance

## What you will learn

Use permutation-safe crossover and a custom parent selector to minimize a round trip.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/03_evolution/03_04_delivery_route/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/03_evolution/03_04_delivery_route/demo.exs
mix test.examples test/examples/03_evolution/03_04_delivery_route --warnings-as-errors
```

The winning route visits each stop once and measures 8 distance units.

## Important behavior

Every recorded route remains a valid permutation. Custom selection receives eligible candidates.

## Limits

The distance model is a small Manhattan metric with no traffic or timing.

[Chapter index](../README.md) · [Previous](../03_03_pack_kit/README.md) · [Next](../03_05_axon_training/README.md)
