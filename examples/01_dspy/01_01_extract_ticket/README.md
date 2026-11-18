# 01_01 Extract a typed ticket

## What you will learn

Preview and call one predictor with the Chat, JSON, and XML adapters.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/01_dspy/01_01_extract_ticket/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/01_dspy/01_01_extract_ticket/demo.exs
MIX_ENV=test mix run examples/01_dspy/01_01_extract_ticket/demo.exs --preview-only
mix test.examples test/examples/01_dspy/01_01_extract_ticket --warnings-as-errors
```

All three calls return billing with confidence 0.8. With `--preview-only`,
the demo prints the full Chat, JSON, and XML messages, including the
demonstration, and reports zero model requests.

## Important behavior

A reply with missing or invalid fields returns an execution error.

## Limits

The fixture compares typed output for one ticket. It does not compare model accuracy across formats.

[Chapter index](../README.md) · [Next](../01_02_labeled_routing/README.md)
