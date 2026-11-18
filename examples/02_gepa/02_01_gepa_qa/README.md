# 02_01 Reflect on multi-hop QA

## What you will learn

Send feedback about missing evidence and unsupported answers to GEPA with two independent validation cases.

## Read the code

Read [the workflow](../support/multi_hop_qa.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/02_gepa/02_01_gepa_qa/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/02_gepa/02_01_gepa_qa/demo.exs
mix test.examples test/examples/02_gepa/02_01_gepa_qa --warnings-as-errors
```

Per-row scores show one candidate solving Pine Bridge, another solving Copper Bridge, and a winner scoring 1.0.

## Important behavior

The same training minibatch scores each parent and its challenger. A child that cannot beat its parent does not reach validation.

## Limits

The small HotpotQA-style fixture proves the search path. It does not measure performance on HotpotQA.

## Core Fit and Gaps

Per-row results and lineage come from Tune. The application defines feedback about evidence quality.

[Chapter index](../README.md) · [Next](../02_02_gepa_merge/README.md)
