---
title: Refactor Tune around three clean architecture seams
type: implementation-plan
date: 2026-11-14
last_reviewed: 2026-11-14
artifact_contract: kata-plan/v1
artifact_readiness: implementation-ready
domain: software
execution: code
product_contract_source: direct-request
---

# Refactor Tune around three clean architecture seams

## Goal Capsule

- **Objective:** Keep the typed LLM runtime, evaluation framework, fifteen LLM
  strategies, and genetic search in Tune, with one owner for each shared rule.
- **Means:** Add canonical evaluation and study contracts, move all callers to
  them, then remove duplicate types, state, scoring, and artifact code.
- **Authority:** This plan permits later local Tune source changes only after a
  separate implementation request. It does not permit a commit, push, release,
  publication, live provider call, or sibling-package change.
- **Stop conditions:** Stop implementation if a unit removes one of the fifteen
  strategy tags, changes the twelve-name facade, adds a compatibility layer, or
  makes Runtime depend on Evaluation or Search.
- **Next executor:** An Elixir package maintainer working in unit dependency order.

## Product Contract

### Summary

Tune remains one package with three capabilities:

1. A typed LLM program runtime.
2. An evaluation and scoring framework.
3. Program search with fifteen LLM strategies, plus generic genetic search.

The work reduces duplicate ownership. It does not reduce the product scope.

### Problem Frame

The current package has working behavior and passing offline checks. Its main
cost is duplicate ownership:

- `Tune` and `Tune.Pipeline.Evaluator` both execute and select scores.
- `Tune.Search.Context` and `Tune.Search.Genetic` both own search state.
- `Tune.Example` and `Tune.Case` both describe a dataset row.
- `Tune.Metric`, `Tune.Score`, and `Tune.Pipeline.Score` split one score contract.
- `Tune.Parameters` and `Tune.Artifact` define two artifact models.
- `Tune` and `Tune.Search.Context` both build runtime-to-evaluation runners.

The code must keep the algorithms. It must remove the competing owners.

### Actors

- Program authors define typed predictors and composed programs.
- Evaluators define cases, scores, selectors, and limits.
- Search users select one of fifteen program strategies or generic genetic search.
- Applications own tools, effects, credentials, persistence, and deployment.

### Requirements

| ID | Required behavior |
| --- | --- |
| R1 | Keep the twelve public workflow names and the immutable `%Tune{}` pipeline. |
| R2 | Runtime owns typed programs, model roles, adapters, execution, and predictions. It has no dependency on Evaluation or Search. |
| R3 | Evaluation owns one case type, one score executor, one selector, observations, summaries, judge accounting, and one evaluator implementation. |
| R4 | Each evaluation consumes its source once. Search requests a fresh source for each candidate. |
| R5 | One study owner holds candidate IDs, history, the incumbent, random state, limits, counters, deadlines, stop reason, and final result construction. |
| R6 | Keep all fifteen program strategy tags. Thirteen can change declared parameters. KNN and Ensemble can return typed runtime program constructors. |
| R7 | Generic genetic search owns only populations, spaces, mutation, crossover, tournament selection, and elitism. It has no program, adapter, prediction, or ReqLLM dependency. |
| R8 | Runtime, Evaluation, and Study use one nested accounting chain. Hidden calls in an opaque generic runner remain application-owned unless the runner reports them. |
| R9 | `Tune.Artifact` alone owns the public wire format, fingerprints, encoding, decoding, provenance projection, and atomic apply. |
| R10 | The optional UI uses only public Tune APIs and owns no core runtime, evaluation, or search rule. |
| R11 | Keep all default checks offline, with no credentials, Python, Jido, or live provider calls. |

### Key Flows

Typed program evaluation:

```text
%Tune{} -> pipeline compile -> Runtime target -> Evaluation -> %Tune.Evaluation{}
```

Program search:

```text
%Tune{} -> Program strategy -> Runtime and Evaluation -> Study -> %Tune.Result{}
```

Generic genetic search:

```text
%Tune{} -> Genetic and Space -> opaque runner and Evaluation -> Study -> %Tune.Result{}
```

Artifact flow:

```text
%Tune.Result{} -> Tune.Artifact -> JSON -> validate -> atomic apply
```

### Acceptance Examples

- **A1:** The current public pipeline examples still compile and run offline.
- **A2:** A function score, module score, and struct score use the same executor
  during direct evaluation and program search.
- **A3:** Weighted selection produces the same value in direct evaluation and
  candidate search because only one selector implementation exists.
- **A4:** A program row becomes one `%Tune.Case{}`. No `Tune.Example` conversion
  is stored in case metadata.
- **A5:** Judge calls and judge token use enter the evaluation total. Study adds
  that total once.
- **A6:** Program and genetic search both use one Study for IDs, history, the
  incumbent, accounting, limits, stop reason, and result construction.
- **A7:** All fifteen program strategy tests pass. KNN and Ensemble still return
  runnable typed programs.
- **A8:** Genetic search has no dependency on `Tune.Program`, `Tune.Prediction`,
  adapters, or ReqLLM.
- **A9:** One artifact format reloads program and generic results. A mismatch
  changes no target value.
- **A10:** `Tune.UI` continues to call the public facade only.

### Success Criteria

- One module owns each shared rule named in R2-R9.
- The old duplicate modules and private implementations are removed.
- All 196 or more offline tests pass.
- `mix quality` and `mix docs` pass.
- The package keeps the same three capabilities and all fifteen strategy tags.

### Scope Boundaries

In scope:

- Runtime-to-evaluation adaptation.
- Case, score, selector, evaluator, study, result, and artifact ownership.
- The fifteen program strategy callers.
- The genetic engine and variation spaces.
- The twelve-name facade, guides, examples, and related tests.

Out of scope:

- New strategies, new score types, or new variation spaces.
- Provider transport, retries, tools, agents, persistence, or deployment.
- A permanent optimization process, run registry, or storage service.
- Changes to ReqLLM, Jido, Nx, Axon, `jido_eval`, or `jido_evolve`.
- A public compatibility layer for the current unreleased internals.
- Publication, release, license, commit, or push work.

### Key Decisions

- Keep the three capabilities in one package.
- Keep separate program and genetic mechanics.
- Share Evaluation, Study, Candidate, Result, and Artifact contracts.
- Use direct replacement because Tune is unpublished at version `0.1.0`.
- Keep the fifteen strategy modules. File count is not a removal target.

### Rejected Alternatives

- **Merge the two search loops:** Their proposal and mutation mechanics differ.
- **Keep two search-state owners:** This keeps duplicate budgets and results.
- **Wrap old internal types:** This leaves the duplicate model in place.
- **Move one capability to another package:** The requested scope keeps all three.
- **Delete strategy modules to reduce lines:** The modules hold distinct behavior.

### Dependencies

No new dependency is required. ReqLLM, Zoi, Splode, Elixir's built-in JSON
module, and the current test dependencies remain unchanged.

### Outstanding Questions

None block implementation.

### Sources

- [Tune first-release plan](2026-11-14-0936-core-plan.md)
- [Pipeline consolidation plan](2026-11-14-1525-pipeline-consolidation-plan.md)
- [Package facade](../../lib/tune.ex)
- [Program runtime](../../lib/tune/runtime.ex)
- [Current evaluator](../../lib/tune/pipeline/evaluator.ex)
- [Current program search context](../../lib/tune/search/context.ex)
- [Current genetic engine](../../lib/tune/search/genetic.ex)
- [Current parameter format](../../lib/tune/parameters.ex)
- [Current artifact format](../../lib/tune/artifact.ex)

## Planning Contract

### Product Contract Preservation

Product Contract unchanged. This plan refines the ownership and removal order
for the behavior that the two earlier plans already require.

### Current System

The reviewed source is commit `cb087ede8cafa73056d87ba7842665652f88e02c`
plus current uncommitted UI work. The UI work is outside the refactor target and
must be preserved.

The main duplicate surfaces contain about 2,844 lines before optimizer callers:

- `lib/tune.ex`: facade, compilation, scoring, selection, search dispatch,
  runtime runners, and artifact conversion.
- `lib/tune/pipeline/evaluator.ex`: row execution, scores, selection, statistics,
  concurrency, limits, and accounting.
- `lib/tune/search/context.ex`: program search data, runtime calls, evaluation,
  study state, random state, and result construction.
- `lib/tune/search/genetic.ex`: genetic mechanics plus a second study state.
- `lib/tune/parameters.ex` and `lib/tune/artifact.ex`: two artifact contracts.
- `lib/tune/example.ex`, `lib/tune/case.ex`, `lib/tune/metric.ex`,
  `lib/tune/score.ex`, and `lib/tune/pipeline/score.ex`: overlapping data and
  score contracts.

Current `mix test` passes 196 tests. Current `mix quality` passes. These checks
prove the current state, not the future refactor.

### Target System

```text
Tune facade and Pipeline.Compiler
├── Runtime and Runtime.Target ───────────────> ReqLLM
├── Case, Score, Score.Selector, Evaluator
└── Search
    ├── Study
    ├── Program, Program.Context, 15 strategies ──> Runtime + Evaluator + Study
    └── Genetic + Space ──────────────────────────> Evaluator + Study

Result -> Artifact
UI -> public Tune API only
```

Runtime does not import Evaluation or Search. Evaluation accepts an opaque
runner and does not import Program, strategy, candidate, or space modules.
Program search and genetic search share Study, but they do not share one
algorithm callback or loop.

### Key Technical Decisions

#### KTD1 — Replace duplicate evaluation contracts directly

- **Decision:** Make `Tune.Case`, `Tune.Score`, `Tune.Score.Selector`, and
  `Tune.Evaluator` the canonical evaluation contracts. Remove `Tune.Example`,
  `Tune.Metric`, `Tune.Pipeline.Score`, and `Tune.Pipeline.Evaluator` after all
  callers move.
- **Reason:** The current types and private functions represent the same row,
  score, and selection rules.
- **Rejected alternative:** Keep adapters between both type families.
- **Consequences:** Program score callbacks receive `Tune.Case` in place of
  `Tune.Example`. One score executor retains the supported function, module, and
  struct callback forms.
- **Governs:** R3-R4, R8, R11; U1, U3, U4, U7.

#### KTD2 — Use Study as the sole shared search-state owner

- **Decision:** Add `Tune.Search.Study`. It owns candidate IDs, history, the
  incumbent, random state, all shared counters, limits, deadline, stop reason,
  and `Tune.Result` construction.
- **Reason:** `Search.Context` and `Search.Genetic` own these values twice.
- **Rejected alternative:** Add a helper around both state maps.
- **Consequences:** Program and genetic engines keep only algorithm-specific
  state. Study accepts completed predictions or evaluations for accounting.
- **Governs:** R5, R7-R8; U2-U4.

#### KTD3 — Keep two search mechanics

- **Decision:** `Tune.Search.Program` owns program-strategy orchestration.
  `Tune.Search.Genetic` owns genetic mechanics. Both use Study and Evaluator.
- **Reason:** Prompt proposal and genetic reproduction are not the same operation.
- **Rejected alternative:** One universal search behavior and loop.
- **Consequences:** There is one result model without a forced algorithm model.
- **Governs:** R5-R7; U2-U4.

#### KTD4 — Put program execution behind one Runtime target

- **Decision:** Add an internal `Tune.Runtime.Target` that normalizes model roles,
  call allowance, execution, output, prediction, and error results. It accepts
  inputs, not `Tune.Case`.
- **Reason:** The facade and program search now build the same runner twice.
- **Rejected alternative:** Let Evaluation know `Tune.Program` and model roles.
- **Consequences:** Pipeline compilation maps `case.input` to the Runtime target.
  Runtime stays below Evaluation.
- **Governs:** R2-R4, R8; U1, U3, U6.

#### KTD5 — Keep all fifteen program strategy modules

- **Decision:** Move their context dependency to
  `Tune.Search.Program.Context`. This context holds program data and delegates
  shared state to Study. Strategies use its run, propose, score, evaluate, and
  consider operations.
- **Reason:** The strategies are distinct algorithms. Their shared problem is
  context ownership, not module count.
- **Rejected alternative:** Inline strategy modules into one large dispatcher.
- **Consequences:** Thirteen strategies can change declared parameters. KNN and
  Ensemble can construct typed programs, which Runtime executes.
- **Governs:** R5-R6, R8; U2-U3.

#### KTD6 — Use one public artifact owner

- **Decision:** `Tune.Artifact` owns the format and public operations. Internal
  `Tune.Artifact.Program` and `Tune.Artifact.Generic` helpers can project and
  apply entries, but they do not define another envelope, version, or codec.
- **Reason:** `Tune.Parameters` and `Tune.Artifact` now use two envelopes and two
  fingerprints.
- **Rejected alternative:** Keep conversion code in the facade.
- **Consequences:** Delete `Tune.Parameters` after its program-entry validation
  moves under `Tune.Artifact.Program`.
- **Governs:** R9; U5-U7.

#### KTD7 — Make the facade a routing surface

- **Decision:** Add internal `Tune.Pipeline.Compiler`. It validates a terminal
  pipeline and returns one normalized Runtime, Evaluation, Program Search, or
  Genetic Search request. `Tune` retains the struct, builders, and twelve public
  function names, then delegates terminal work.
- **Reason:** `Tune` now holds domain logic from all three capabilities.
- **Rejected alternative:** Split private helpers without one compile contract.
- **Consequences:** Strategy tags move to `Tune.Search.Program.Registry`.
  Artifact conversion moves to `Tune.Artifact`.
- **Governs:** R1-R3, R6-R10; U3-U7.

### System Boundaries and Change Surface

| Surface | Current contract | Planned change | Compatibility or risk |
| --- | --- | --- | --- |
| `lib/tune.ex` | Facade plus domain logic | Keep builders and terminals; move compile and execution rules | Twelve names and `%Tune{}` stay stable |
| `lib/tune/example.ex`, `lib/tune/case.ex` | Two row types | Keep one richer `Tune.Case`; delete `Tune.Example` | Program score callbacks receive Case |
| `lib/tune/metric.ex`, `lib/tune/score.ex`, `lib/tune/pipeline/score.ex` | Three score contracts | Replace with one `Tune.Score` and `Tune.Score.Selector` | Callback forms stay supported through one executor |
| `lib/tune/pipeline/evaluator.ex` | Evaluator plus score and selector logic | Replace with `Tune.Evaluator`; delegate score and selection | Row and evaluation results stay public |
| `lib/tune/search/context.ex` | Program context plus shared study state | Replace with `Tune.Search.Program.Context` plus Study | All fifteen optimizers migrate together |
| `lib/tune/search/genetic.ex` | Genetic mechanics plus duplicate study state | Retain mechanics; delegate shared state to Study | Search results keep the same public structs |
| `lib/tune/parameters.ex`, `lib/tune/artifact.ex` | Two artifact formats | Keep one `Tune.Artifact` format and codec | Current unreleased format is replaced directly |
| `lib/tune/ui/**` | Optional facade consumer | No core ownership; update only for public contract changes | Preserve concurrent uncommitted work |

### Implementation Units

#### U1 — Establish the canonical evaluation kernel

- **Outcome:** One case, score, selector, Runtime target, and evaluator path can
  run typed and generic evaluations.
- **Requirements:** R2-R4, R8, R11.
- **Dependencies:** None.
- **Affected surfaces:** The score and evaluation paths in `lib/tune.ex`,
  `lib/tune/case.ex`, `lib/tune/score.ex`, new
  `lib/tune/score/selector.ex`, new `lib/tune/evaluator.ex`, new
  `lib/tune/runtime/target.ex`, `lib/tune/observation.ex`,
  `lib/tune/evaluation.ex`, built-in judge scores, and focused evaluation tests.
- **Implementation direction:** Expand first. Add canonical modules while the old
  modules still exist. Move score callback dispatch and normalization into
  `Tune.Score`. Move selector validation, direction, range normalization, weighted
  selection, and failure-score selection into `Tune.Score.Selector`. Make
  observation eligibility authoritative. Aggregate runtime calls, judge calls,
  and judge token use once. Keep the evaluator independent of Program and Search.
- **Test scenarios:** Function/module/struct scores; one and two score selectors;
  range and direction; row failure with and without failure score; judge calls and
  tokens; timeout; case limit; call limit; generic output; typed prediction.
- **Verification:** Run `mix test test/tune/evaluation_test.exs
  test/tune/judge_scores_test.exs test/tune/pipeline_test.exs` from the Tune root.
- **Completion signal:** Direct evaluation uses only the new kernel, with old
  adapters retained only for unmigrated search callers.

#### U2 — Add the sole Study owner

- **Outcome:** `Tune.Search.Study` owns all state shared by program and genetic search.
- **Requirements:** R5, R7-R8.
- **Dependencies:** U1.
- **Affected surfaces:** New `lib/tune/search/study.ex`, `lib/tune/candidate.ex`,
  `lib/tune/result.ex`, and new focused study tests.
- **Implementation direction:** Move ID allocation, history, incumbent rules,
  tie handling, accounting, random state, evaluation count, model-call count,
  deadline, stop reason, and result construction into Study. Accept candidate
  values and parameters as opaque terms. Do not import Program, Space, adapters,
  or ReqLLM. Provide one controlled random-state operation for engine-specific
  Space and optimizer work.
- **Test scenarios:** Earlier candidate wins a tie; incomplete or ineligible
  candidates cannot win; first stop reason wins; prediction and evaluation totals
  add once; deadline and limits stop new work; deterministic random state.
- **Verification:** Run the new Study test file and `mix test
  test/tune/optimizers/search_test.exs test/tune/generic_search_test.exs`.
- **Completion signal:** Study can build the same Candidate and Result values for
  both engine types without knowing either algorithm.

#### U3 — Migrate all program search to Runtime, Evaluator, and Study

- **Outcome:** All fifteen program strategies use one program context backed by
  Runtime.Target, Tune.Evaluator, Tune.Score, and Study.
- **Requirements:** R2-R6, R8, R11.
- **Dependencies:** U1, U2.
- **Affected surfaces:** `lib/tune/search/program.ex`,
  `lib/tune/search/program_strategy.ex`, new
  `lib/tune/search/program/context.ex`, new
  `lib/tune/search/program/registry.ex`, all files under
  `lib/tune/optimizers/`, `lib/tune/knn.ex`, `lib/tune/ensemble.ex`, and optimizer tests.
- **Implementation direction:** Move strategy tag lookup out of `Tune`. Replace
  `Tune.Search.Context` with program-only Context. Store Study as its single shared
  state value. Route run, proposal, one-case scoring, full evaluation, candidate
  consideration, random operations, and stop operations through Context. Remove
  direct `Tune.Metric` calls. Preserve KNN and Ensemble as typed program
  constructors. Do not introduce one algorithm loop.
- **Test scenarios:** Every strategy tag compiles; all existing algorithm behavior
  tests pass; score structs guide search; proposal and evaluation calls share one
  budget; partial candidates cannot win; KNN and Ensemble remain runnable.
- **Verification:** Run `mix test test/tune/optimizers test/tune/optimizers/knn_test.exs
  test/tune/ensemble_test.exs test/contracts/qa_release_test.exs`.
- **Completion signal:** No program strategy imports the old Example, Metric,
  Pipeline.Score, Pipeline.Evaluator, or Search.Context modules.

#### U4 — Migrate genetic search to Evaluator and Study

- **Outcome:** Genetic keeps only genetic mechanics and uses the same Evaluation,
  Candidate, Study, and Result contracts as program search.
- **Requirements:** R3-R5, R7-R8, R11.
- **Dependencies:** U1, U2.
- **Affected surfaces:** `lib/tune/search/genetic.ex`, `lib/tune/space.ex`,
  `lib/tune/space/*.ex`, and `test/tune/generic_search_test.exs`.
- **Implementation direction:** Remove IDs, history, incumbent, random state,
  shared counters, deadline, stop reason, and result construction from Genetic.
  Keep population, generation, reproduction, tournament, elitism, and Space calls.
  Request a fresh validation source for each candidate. Report opaque runner
  accounting only when the runner returns it. Do not add Program or ReqLLM imports.
- **Test scenarios:** Deterministic seeded result; evaluation limit; deadline;
  cancellation; failed candidate retention; no eligible parent; valid sampling,
  mutation, and crossover; opaque values pass through unchanged.
- **Verification:** Run `mix test test/tune/generic_search_test.exs
  test/contracts/nx_axon_compatibility_test.exs` and inspect `mix xref graph --format plain`.
- **Completion signal:** Genetic has one Study value and no duplicate shared
  search-state fields or forbidden dependencies.

#### U5 — Replace the two artifact models with Tune.Artifact

- **Outcome:** One versioned artifact format dumps and loads program and generic results.
- **Requirements:** R9, R11.
- **Dependencies:** U3, U4.
- **Affected surfaces:** `lib/tune/artifact.ex`, new internal
  `lib/tune/artifact/program.ex`, new internal
  `lib/tune/artifact/generic.ex`, new `lib/tune/canonical_json.ex`,
  `lib/tune/parameters.ex`, facade dump/load code, artifact tests, and the artifact guide.
- **Implementation direction:** Move canonical JSON out of Example. Keep one
  envelope, size limit, version, key validation, provenance allowlist, and codec in
  `Tune.Artifact`. Program and Generic helpers only project entries, compute their
  contract data, validate target compatibility, and apply all updates atomically.
  Remove all Result and Evaluation knowledge from the entry codec. Build safe
  provenance before calling Artifact.
- **Test scenarios:** Program round trip; generic round trip; unknown fields;
  size limit; changed name, kind, or schema; invalid JSON value; no partial apply;
  no code, credentials, runtime options, responses, or opaque values in JSON.
- **Verification:** Run `mix test test/contracts/artifact_test.exs
  test/tune/pipeline_test.exs test/contracts/qa_release_test.exs`.
- **Completion signal:** `Tune.Parameters` has no callers and can be deleted.

#### U6 — Make Tune a thin facade and compiler entry

- **Outcome:** `Tune` keeps the pipeline struct, seven builders, and five terminal
  or artifact functions. Domain work is delegated to its owner.
- **Requirements:** R1-R10.
- **Dependencies:** U3, U4, U5.
- **Affected surfaces:** `lib/tune.ex`, new `lib/tune/pipeline/compiler.ex`,
  program registry, Runtime.Target, Evaluator, both search engines, Artifact,
  pipeline tests, and optional UI call sites.
- **Implementation direction:** Move dataset factories, terminal validation,
  runtime options, target compilation, strategy selection, spaces, and runner
  adaptation into Pipeline.Compiler. Keep builder-local validation in `Tune`.
  `preview`, `evaluate`, `tune`, `dump`, and `load` delegate once. Do not add a
  second public workflow. Confirm UI uses only public modules.
- **Test scenarios:** Twelve-name inventory; builders make no request; terminal
  errors remain tagged; structured evaluation; all program strategy dispatch;
  generic dispatch; preview; artifact dump/load; UI compile and route smoke test.
- **Verification:** Run `mix test test/tune/pipeline_test.exs
  test/tune/ui_test.exs` and inspect the public function inventory.
- **Completion signal:** `Tune` contains no score execution, selector math, search
  state, strategy map, runtime runner body, fingerprint, or artifact entry logic.

#### U7 — Contract old internals and prove the package

- **Outcome:** Duplicate modules and temporary migration code are removed, and
  docs describe the final seams.
- **Requirements:** R1-R11.
- **Dependencies:** U6.
- **Affected surfaces:** Delete `lib/tune/example.ex`, `lib/tune/metric.ex`,
  `lib/tune/pipeline/score.ex`, `lib/tune/pipeline/evaluator.ex`,
  `lib/tune/search/context.ex`, and `lib/tune/parameters.ex`; remove temporary
  adapters; update README, program, optimizer, artifact, compatibility, host, and
  UI guides; update examples and contract tests.
- **Implementation direction:** Search every source, test, guide, and example for
  old module names. Delete only after the search has no supported caller. Add a
  dependency-boundary contract check or a documented xref check for Runtime,
  Evaluation, Program Search, Genetic, Artifact, and UI. Do not reduce strategy
  coverage or weaken tests to make deletion easier.
- **Test scenarios:** No old module references; no forbidden dependencies; all
  examples use the public facade; all fifteen tags remain; UI remains a consumer;
  docs match current callback and artifact contracts.
- **Verification:** Run the full Verification Contract below.
- **Completion signal:** All gates pass on the final source state and the scoped
  diff contains no unrelated or concurrent UI work.

### Work Graph

Initial frontier: U1.

Parallel work: U3 and U4 can run in parallel after U1 and U2. All other work is
serial because each later unit removes or rewires contracts from the prior unit.

Critical path:

```text
U1 -> U2 -> U3 -> U5 -> U6 -> U7
          \-> U4 -/
```

U1 supplies canonical evaluation contracts. U2 supplies Study. U3 and U4 move
both search engines. U5 fixes the final Result-to-Artifact shape. U6 removes
domain logic from the facade. U7 deletes the replaced code and runs final proof.

### Verification Contract

| Gate | Applies to | Evidence | Done signal |
| --- | --- | --- | --- |
| Evaluation behavior | U1 | Focused evaluation, judge, and pipeline tests | One executor and selector pass all cases |
| Study invariants | U2 | Focused Study tests | IDs, incumbent, budgets, random state, and stop rules pass |
| Program strategies | U3 | All optimizer, KNN, Ensemble, and QA tests | All fifteen tags pass through new Context |
| Genetic behavior | U4 | Generic and Nx/Axon contract tests | Genetic uses Study and keeps deterministic results |
| Artifact safety | U5 | Artifact and release contract tests | One format round-trips and rejects mismatches atomically |
| Facade and UI | U6 | Pipeline and UI tests | Twelve names remain and UI uses public APIs |
| Dependency direction | U7 | `mix xref graph --format plain` plus old-name search | No forbidden edge or old owner remains |
| Repository tests | U7 | `mix test` | All offline tests pass |
| Static quality | U7 | `mix quality` | Format, compile, Credo, and Dialyzer pass |
| Documentation | U7 | `mix docs` | Docs build with no broken module reference |

Run final commands from `/Users/mhostetler/Source/ReqLLM/tune`:

```sh
mix test
mix quality
mix docs
mix xref graph --format plain
git diff --check
```

Requirement traceability:

| Requirement | Units | Main proof |
| --- | --- | --- |
| R1 | U6-U7 | Public inventory and pipeline tests |
| R2 | U1, U3, U6-U7 | Runtime and xref checks |
| R3 | U1, U3-U4, U7 | Evaluation, judge, and old-name checks |
| R4 | U1, U3-U4 | Stream and candidate evaluation tests |
| R5 | U2-U4 | Study invariant and search tests |
| R6 | U3, U7 | Full optimizer suite and tag inventory |
| R7 | U2, U4, U7 | Generic search tests and xref check |
| R8 | U1-U4 | Budget, call, usage, and stop tests |
| R9 | U5-U7 | Artifact contract tests |
| R10 | U6-U7 | UI tests and dependency check |
| R11 | U1-U7 | Full offline gates |

### Rollout and Recovery

This is an unpublished local library. No deployment or data migration exists.
Use expand, migrate, and contract inside the worktree: add canonical owners in
U1-U2, move callers in U3-U6, and delete old owners in U7. If a unit fails, keep
the last verified unit and repair the current unit. Do not add a public
compatibility layer.

### Risks and Assumptions

- **Risk:** A strategy bypasses Study and loses accounting. **Control:** Context
  is the only strategy operation surface, with budget regression tests.
- **Risk:** Case migration changes callback values. **Control:** Document and test
  the Case callback contract before old Example code is removed.
- **Risk:** Judge token use remains outside totals. **Control:** Add a response
  usage assertion in U1.
- **Risk:** Genetic random behavior changes. **Control:** Keep seeded behavior
  tests before and after U4. Exact parity beyond current tests is not required.
- **Risk:** Artifact replacement weakens atomic apply. **Control:** Move existing
  mismatch tests before deleting Parameters.
- **Risk:** Concurrent uncommitted UI work is overwritten. **Control:** Treat all
  current UI files and manifest edits as user work. Modify them only when U6
  requires a public-call update, and inspect the scoped diff before U7 ends.
- **Assumption:** Tune remains unpublished, so no compatibility window is needed.

### Open Planning Decisions

None.

### Definition of Done

- Runtime, Evaluation, Study, Program Search, Genetic, Artifact, and UI follow
  the dependency rules in the Target System.
- The six old duplicate module files named in U7 are removed.
- One Case, one Score executor, one Selector, one Evaluator, one Study, one
  Candidate/Result family, and one Artifact format remain.
- All fifteen program strategy tags and generic genetic search pass offline tests.
- Runtime and judge accounting roll into Evaluation, then Study, exactly once.
- `Tune` retains the twelve public workflow names and contains no domain logic
  listed in U6.
- UI remains a public-API consumer.
- `mix test`, `mix quality`, `mix docs`, xref inspection, and `git diff --check`
  pass on the final source state.
- Documentation and examples describe the final contracts.
- No commit, push, publication, release, or sibling-package change is required.

### Planning Sources

- [Tune package instructions](../../AGENTS.md)
- [Tune README](../../README.md)
- [Programs and evaluation guide](../../guides/programs.md)
- [Search strategies guide](../../guides/optimizers.md)
- [Artifact guide](../../guides/artifacts.md)
- [Compatibility guide](../../guides/compatibility.md)
- Current modules and tests named in each implementation unit.

## Adapter Results

- Markdown: canonical at `docs/plans/2026-11-14-2031-architecture-seams-refactor-plan.md`
- HTML: not requested
- Beadwork: not requested
