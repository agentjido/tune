# AGENTS.md - Tune Development Guide

**IMPORTANT: DO NOT WRITE COMMENTS INTO THE BODY OF ANY FUNCTIONS.**

## Project Overview

Tune is an Elixir library that measures and improves Elixir code, including
LLM prompts. It runs a function or LLM program on labeled cases, scores the
outputs, searches for a better configuration or prompt, and compares the
winner with the baseline on a held-out split. Learned values export as
versioned JSON artifacts.

Tune sends model calls through [ReqLLM](https://github.com/agentjido/req_llm)
and reads model metadata from [LLMDB](https://github.com/agentjido/llmdb).
The host application owns credentials, tools, side effects, and deployment.

## Authority

- Do not commit, push, open pull requests, tag, build or publish Hex
  packages, or change the license without an explicit request for that action.
- Do not call live or paid provider APIs without explicit permission. Local
  Ollama or LM Studio runs are allowed when requested.
- Preserve unrelated and uncommitted work.

## Common Commands

Run Mix commands from the repository root.

- `mix deps.get` - Install dependencies
- `mix test` - Run all tests with scripted responses
- `mix test test/tune/grid_search_test.exs` - Run one test file
- `mix test.examples` - Run the offline example suite under `test/examples/`
- `mix quality` or `mix q` - Format check, `compile --warnings-as-errors`,
  `credo --strict`, and `dialyzer`
- `mix docs` - Build ExDoc output in `doc/`
- `bash .github/scripts/check-docs.sh` - Verify generated docs and README links
- `mix tune.ui` - Start the optional local workbench (needs Phoenix Playground)

Default checks need no credentials and make no live provider calls.

## Architecture & Structure

### Public API

- `lib/tune.ex` - Lazy study builder. `new/2`, `data/2`, `score/4`, `vary/2`,
  and `search/3` return a new `%Tune{}` and do no work. `preview/2`,
  `evaluate/2`, `tune/1`, and `compare/3` run it. `dump/1` and `load/2`
  move learned values in and out of artifacts.
- `Tune.Program` - Behaviour for LLM programs: `signature/1`, `parameters/1`,
  `put_parameters/2`, and `call/3`.
- `Tune.Predictor`, `Tune.Signature`, `Tune.Parameter` - Tunable program parts.
- `Tune.Execution` - Runs predictors inside `call/3` and records steps.
- `Tune.Result`, `Tune.Comparison`, `Tune.Evaluation` - Run outputs.
- `Tune.Artifact` - Versioned JSON export of learned values.

### Internals

- `lib/tune/pipeline/` - Compiles a study into a runnable pipeline.
- `lib/tune/search/` - Grid, genetic, and program search drivers.
- `lib/tune/optimizers/` - Prompt and demonstration strategies, such as
  bootstrap few-shot, MIPROv2, COPRO, SIMBA, and GEPA.
- `lib/tune/space/` - Search space types: choice, integer, float, subset, text.
- `lib/tune/adapter/` - Chat, JSON, XML, and text prompt adapters.
- `lib/tune/score/`, `lib/tune/scores/` - Score selection, summaries, and
  judge-based scores.
- `lib/tune/runtime/` - Model call boundary to ReqLLM.
- `lib/tune/ui/` - Optional Phoenix Playground workbench.
- `lib/mix/tasks/` - `mix tune.ui`.

## Design Rules

- Follow the patterns in [ReqLLM](https://github.com/agentjido/req_llm).
- Normalize public input once. Use one canonical value shape inside each
  boundary.
- Use explicit structs, pattern matching, small functions, and immutable
  updates.
- Use Zoi for data contracts and Splode for package-owned errors.
- Preserve ReqLLM responses and errors. Do not copy ReqLLM provider logic.
- Add a dependency only when code uses it. Declare direct dependencies
  explicitly.
- Keep runtime model configuration and credentials out of learned parameters.
  Artifacts may hold explicitly allowed non-secret configuration provenance.
  Never serialize raw runtime options, credentials, functions, or response
  structs.
- Keep composition in ordinary Elixir code. Do not add a macro DSL or a
  workflow engine.
- Keep adapters pure: render prompts and parse replies. Repair and extraction
  are explicit program steps. ReqLLM owns transport retries.
- Keep the target configuration and adapter fixed during optimization. Teacher
  and proposal configurations are separate and explicit.
- Require no Python runtime for installation, compilation, execution, or
  default checks. Do not bundle or start Python workers. Optional training
  backends must follow this rule and stay outside the prompt core.
- Keep Jido optional. Preserve its inference controls at the host integration
  boundary.

## Testing

- Place behavior tests under `test/tune/` and contract tests under
  `test/contracts/`. Keep test helpers under `test/support/`.
- Example tests live under `test/examples/` and follow
  [examples/AGENTS.md](examples/AGENTS.md).
- Model calls in tests use scripted ReqLLM replies through an in-process Plug.
- Test behavior and invariants. Do not add tests that only mirror code.
- Add a test for every change to public behavior.

## Documentation

- Package guides live in `guides/` and publish to HexDocs. Add a new guide to
  `guide_toc/0` in `mix.exs`.
- Development docs, plans, and progress notes live in `docs/` and are not
  packaged. Keep implementation plans in `docs/plans/` stable during
  execution; record progress in `docs/progress/`.
- README and `guides/compatibility.md` link to examples at the release tag,
  for example `tree/v<version>/examples`. GitOps updates these links with the
  version; do not edit them by hand.

## Release Hygiene

- Use Conventional Commits, such as `fix(runtime): record token usage`. CI
  checks new commit messages. Use `feat` for public API additions and `!` or a
  `BREAKING CHANGE` footer for breaking changes.
- Do not modify `CHANGELOG.md` or `@version` in `mix.exs` by hand. GitOps
  generates them, and the versioned example links, in the release pull request.
- Follow [docs/releasing.md](docs/releasing.md). GitHub Actions creates the
  tag, publishes to Hex, and creates the GitHub Release.
