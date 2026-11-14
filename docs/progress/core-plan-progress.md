# Core plan progress

Temporary execution record for
[the core plan](../plans/2026-11-14-0936-core-plan.md). The plan stays stable;
this file records what is built and verified.

## Status

| Unit | State | Main evidence |
| --- | --- | --- |
| U1 typed predictor | Done | `predictor_test`, `adapter_test`, `host_boundary_test` |
| U2 composition and parameters | Done | `composition_test` |
| U3 evaluation | Done | `evaluation_test` |
| U4 example learning | Done | `optimizers/example_learning_test` |
| U5 artifacts | Done | `contracts/artifact_test` |
| U7 XML | Done | `xml_adapter_test` |
| U8 random search, Optuna family | Done | `optimizers/search_test` |
| U9 KNNFewShot | Done | `optimizers/knn_test` |
| U10 Ensemble | Done | `ensemble_test` |
| U11 COPRO, SignatureOptimizer | Done | `optimizers/instruction_search_test` |
| U12 MIPROv2 | Done | `optimizers/mipro_v2_test` |
| U13 InferRules | Done | `optimizers/infer_rules_test` |
| U14 SIMBA | Done | `optimizers/simba_test` |
| U15 GEPA, U18 Optimize.Anything | Done | `optimizers/reflective_test` |
| U16 Avatar, U17 Playbook | Done | `optimizers/avatar_playbook_test` |
| U6 final proof | Done within revised scope | see below; Hex packaging removed by owner |

## U6

Done:

- Offline QA comparison through Chat, JSON, and XML with prompt previews,
  parse success, tokens, calls, and artifact reload: `contracts/qa_release_test`.
- `mix quality` (format, warnings-as-errors, `credo --strict` with ReqLLM's
  Credo config, Dialyzer) and `mix test` pass on Elixir 1.20.4 / OTP 29.
- `mix docs` builds without warnings. Guides are in `guides/`.
- A fresh consumer project compiled the package files with only published
  runtime dependencies and ran prepare, dump, encode, decode, and apply.
- Runtime matrix before the package rename (`examples/runtime_matrix.sh`, run outside the sandbox):
  Elixir 1.18.4 / OTP 27.3, 1.19.5 / OTP 28.5, and 1.20.4 / OTP 29.1 each
  compile with warnings as errors and pass all 173 tests.
- Local Ollama proof (`examples/ollama_examples.exs`, target `lfm3:latest`,
  teacher `qwen3.8:27b`): the classifier returned correct typed output for
  3/3 tickets in each of Chat, JSON, and XML; grounded QA ran both steps and
  cited the right source; the BootstrapFewShotWithRandomSearch comparison on
  3 test rows measured Chat 0.000 -> 0.667 (parse 0% -> 67%), JSON
  1.000 -> 1.000 (zero-shot kept), XML 0.500 -> 0.500; the artifact reloaded
  equal to the optimized program. These are single-run measurements.
- `examples/ollama_reload.exs` loaded the saved artifact into fresh code and
  answered 1 of 3 questions; the other 2 were retained parse errors from
  malformed Chat markers emitted by the small model.

Outside the current scope:

- The owner removed Hex packaging from the plan. License and publication
  remain separate decisions; no package build was made.
- Paid-provider comparison was not run. `examples/live_comparison.exs` was run
  against local Ollama instead (`lfm3:latest` target, `qwen3.8:27b` teacher;
  2 train, 2 validation, 2 test rows): test scores Chat 0.500 -> 0.000
  (parse 50% -> 0%), JSON 1.000 -> 1.000, XML 0.700 -> 0.500; all reloads
  matched. Validation-selected candidates did not improve the tiny test set
  for this small model; this is a measurement, not a defect.

## Findings during implementation

- Naming update: the local directory and Mix application are `tune`; public
  modules use `Tune`. This is a rename only. Eval/Evolve consolidation, Nx/Axon
  integration, and model training remain outside the implementation scope.
- New artifacts use `tune.parameters`, version 1. The loader accepts the old
  `req_llm_program.parameters` identifier. Payloads and fingerprints are
  unchanged; old Elixir module names are not provided as compatibility aliases.
- Rename verification on Elixir 1.20.4 / OTP 29.1.2: all 173 existing tests,
  `mix quality`, and `mix docs` passed. Prompt inspection and offline QA ran
  through all three adapters with matching reloads. A pre-rename artifact
  passed decode and direct apply, retained its entries, and encoded with the
  Tune identifier. Unknown versions and unrelated formats were rejected.
  The dependency lockfile and golden prompt fixtures are unchanged. No new
  tests or live-provider calls were added for this rename.
- Review corrections: fingerprints now remove annotations only at schema
  positions; C1 is a required dependency of U9-U18. The owner requested no
  regression tests for these changes.
- Runnable prompt inspection and offline QA examples are documented in
  `examples/README.md`. The QA script uses the existing offline reply helpers.
- Follow-up verification: both scripts ran through Chat, JSON, and XML. The
  offline QA handler produced the expected `0.0 -> 1.0` score and matching
  reloads for all three formats. These are scripted values, not model quality
  measurements. The existing 173 tests, `mix quality`, and `mix docs` passed.
- Manual artifact checks used nested properties named `title`, `description`,
  `examples`, and `$schema`: prose changes preserved identity, while schema
  changes produced different fingerprints and were rejected on load. Test
  files were unchanged. The existing Ollama reload script was formatted.
- ReqLLM 1.30.0 coerces a string `"0.8"` into a float in structured output
  and reports `:legacy_type_coercion`; it is rejected as a repair.
- A local model emitted `[[ ## label ##]]`; Chat markers now accept irregular
  spacing around `##`. Values are never changed.
- The pinned DSPy commit's `pyproject.toml` declares version 3.4.1, not 3.5.0.
  DSPy pins `gepa>=0.1.4,<0.2.0` and `optuna>=3.4.0` as ranges, not versions.
- The first ReqLLM call in a VM takes about a second; very small evaluation
  row timeouts can expire on it.

## Environment

In the sandboxed agent shell, Mix must run with `MIX_OS_CONCURRENCY_LOCK=0`.
Local Ollama is reachable only outside the sandbox (the Terminal panel).
