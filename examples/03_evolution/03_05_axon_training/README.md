# 03_05 Tune Axon training

## What you will learn

Use a fixed batch and application-owned Axon training for each hyperparameter choice.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/03_evolution/03_05_axon_training/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/03_evolution/03_05_axon_training/demo.exs
mix test.examples test/examples/03_evolution/03_05_axon_training --warnings-as-errors
```

The selected learning rate reloads into a new configuration, and its validation loss is lower than the baseline.

## Important behavior

The runner retains opaque Nx and Axon state. The artifact contains only the portable learning rate.

## Limits

The model is a small synthetic regression. Tune does not persist the trained weights.

## Core Fit and Gaps

Tune can pass opaque training state through evaluation. The application owns model setup, the optimizer, trained weights, and any model file format.

[Chapter index](../README.md) · [Previous](../03_04_delivery_route/README.md) · [Next](../03_06_dispatch_queue/README.md)
