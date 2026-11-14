# Pipeline consolidation progress

This file records implementation work for the pipeline consolidation plan. The
plan stays unchanged.

## Completed work

- Replaced the eager Tune facade with one immutable lazy pipeline.
- Kept the twelve selected top-level workflow function names.
- Added stable pipeline, case, observation, evaluation, candidate, result,
  score-summary, prediction, search-context, and artifact structs.
- Replaced the duplicate evaluator with one bounded evaluation engine.
- Added named scores, weighted selection, feedback, failure scores, and retained
  row errors.
- Added faithfulness and context-precision scores through ReqLLM.
- Moved all prompt and example strategies to the common search context.
- Added the ensemble strategy to complete the fifteen selected targets.
- Added generic spaces and bounded genetic search.
- Added safe Tune artifacts and removed the old artifact format reader.
- Added an offline Nx and Axon compatibility proof.
- Removed the old facade, optimizer context, duplicate evaluator, comparison
  harness, provider scripts, and migration material.
- Replaced the documentation with one lazy pipeline workflow.

## Scope boundaries

- ReqLLM owns provider transport and transport retries.
- Tune owns programs, scores, evaluation, selection, search, and artifacts.
- Applications own tools, agent loops, hidden runner effects, persistence,
  credentials, training, and deployment.
- Tune has no runtime dependency on Jido, Nx, Axon, `jido_eval`,
  `jido_evolve`, or Python.
- Tune does not provide compatibility aliases or readers for abandoned APIs.

## Verification

Verified on Elixir 1.20.4 and OTP 29.1.2:

- `mix test`: 192 tests passed.
- `mix quality`: formatting, warnings-as-errors compilation, strict Credo, and
  Dialyzer passed.
- `mix docs`: documentation built with no warnings.
- `mix deps.unlock --check-unused`: no unused lock entries were found.
- `examples/inspect_prompts.exs`: rendered Chat, JSON, and XML prompts with no
  model call.
- `examples/lazy_structured_prompt.exs`: improved the scripted selected score
  from `0.2` to `1.0` and printed the learned demonstration.
- `examples/generic_genetic.exs`: selected batch size 7 with score 100 and
  reloaded the artifact.

The sandbox reports an expected Mix event-subscription `:eperm` warning. It does
not change command results.
