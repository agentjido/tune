# 05_02 Run and compare studies in the workbench

## What you will learn

Submit saved answers, search a router, choose the holdout, and download the learned artifact.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/05_application/05_02_workbench/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/05_application/05_02_workbench/demo.exs
mix test.examples test/examples/05_application/05_02_workbench --warnings-as-errors
```

Saved accuracy is 1.0. Two source training rows become one effective case. Comparison improves one row and the download returns 200.

## Important behavior

Comparison requires an explicit non-empty split. A later study edit leaves old comparison evidence visible.

## Limits

The runner exercises the workbench in-process. It does not start a Phoenix listener or test browser behavior.

## Core Fit and Gaps

Workbench recipes let application code declare tests and model configuration. The local store retains evidence for the lifetime of its process.

[Chapter index](../README.md) · [Previous](../05_01_router_service/README.md)
