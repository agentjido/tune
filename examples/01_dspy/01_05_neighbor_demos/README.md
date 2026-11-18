# 01_05 Retrieve nearby demonstrations

## What you will learn

Use KNNFewShot to bootstrap a different demonstration for each ticket.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_05_neighbor_demos/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_05_neighbor_demos/demo.exs
mix test.examples test/examples/01_dspy/01_05_neighbor_demos --warnings-as-errors
```

A crash selects the startup-crash example and a card refund selects the card-payment example. Each needs one teacher call.

## Important behavior

Equal similarities preserve pool order. Teacher calls consume the shared limit before a target call can start.

## Limits

The local fixture uses text similarity and a small fixed pool.

## Core Fit and Gaps

Nearest-neighbor selection and demo bootstrap compose under one call budget. The application owns the text embedding or vectorizer if it replaces the default.

[Chapter index](../README.md) · [Previous](../01_04_search_demos/README.md) · [Next](../01_06_rewrite_instructions/README.md)
