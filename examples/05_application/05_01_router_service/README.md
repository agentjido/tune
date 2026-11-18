# 05_01 Install a router in an OTP service

## What you will learn

Apply an artifact to fresh trusted code and give each request a program snapshot.

## Read the code

Read [the workflow](example.ex), then [the demo](demo.exs) and [the tests](../../../test/examples/05_application/05_01_router_service/example_test.exs).

## Run it

```sh
MIX_ENV=test mix run examples/05_application/05_01_router_service/demo.exs
mix test.examples test/examples/05_application/05_01_router_service --warnings-as-errors
```

Risk 0.7 routes to general before install and risk-review afterward.

## Important behavior

An incompatible artifact leaves the current program serving. A timed-out worker is cleaned up, and in-flight requests retain their snapshot.

## Limits

The GenServer holds local in-memory state. Durable distribution and rollout are host policy.

## Core Fit and Gaps

Artifact loading and immutable program values compose with OTP. The host owns request supervision and application of a new snapshot.

[Chapter index](../README.md) · [Next](../05_02_workbench/README.md)
