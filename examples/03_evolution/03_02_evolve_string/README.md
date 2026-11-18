# 03_02 Evolve a word

## What you will learn

Seed generation zero with strings and use application crossover and mutation.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/03_evolution/03_02_evolve_string/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/03_evolution/03_02_evolve_string/demo.exs
mix test.examples test/examples/03_evolution/03_02_evolve_string --warnings-as-errors
```

The search reaches TUNE and stops at its target score.

## Important behavior

Duplicate initial genomes receive distinct candidate IDs. A fixed seed repeats the history.

## Limits

The objective counts matching character positions in a four-letter word.

[Chapter index](../README.md) · [Previous](../03_01_batch_grid/README.md) · [Next](../03_03_pack_kit/README.md)
