# 03_06 Evolve and interrupt a dispatch policy

## What you will learn

Run a queue simulator with genetic search and record generation snapshots.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/03_evolution/03_06_dispatch_queue/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/03_evolution/03_06_dispatch_queue/demo.exs
mix test.examples test/examples/03_evolution/03_06_dispatch_queue --warnings-as-errors
```

The deadline policy completes four jobs on time and stops on patience.

## Important behavior

Cancellation and deadlines stop work. An incomplete generation stays in history without replacing the last completed incumbent.

## Limits

The queue uses deterministic jobs. Distributed job dispatch and durable state are host concerns.

## Core Fit and Gaps

Tune supplies bounded evaluations, stop reasons, and candidate history. The application defines the queue, fitness, variation, and snapshot storage.

[Chapter index](../README.md) · [Previous](../03_05_axon_training/README.md)
