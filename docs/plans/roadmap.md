---
title: Tune roadmap ideas
status: draft
last_reviewed: 2026-11-19
---

# Tune roadmap ideas

Tune gives Elixir teams a small library for scoring runs and searching for
better parameters. Keep one case and score contract, one accounting path, and
one deployable parameter format. Use explicit values and callbacks at the
boundaries. Keep a program's control flow in ordinary Elixir. Use the behavior
of other libraries as a reference when it solves a problem for Tune users.

This is a working list of ideas for review. Priorities are proposed. The
immediate goal is to show that a host can use Tune to detect and explain a
regression in a Jido v3 agent.

## Decisions already made

- Keep Jido out of Tune's dependencies. The host or a standalone Livebook
  installs both and owns the adapter from Jido results to Tune rows.
- Keep provider transport, structured response handling, and retries in
  ReqLLM. Tune owns scoring, search, and accounting for calls it manages.
- Keep deployable artifacts as data that the host applies to existing code.
  Keep program execution, tools, effects, and deployment in the host.
- Keep the default test suite offline and free of provider credentials.

## Proposed order

### 1. Show two traces and add a live smoke test

Start with [Compare two Jido agent traces](../jido-agent-eval.md). Run the same
case with fresh agent state and scripted inference. Check the answer and tool
evidence separately. Record stable case IDs. Score each trace with the same
scorers through `Tune.replay/2` and `Tune.evaluate/2`, then pair them in the
host. Both traces should give the same answer and only one should show a
successful lookup. This example needs no Tune API change. `Tune.compare/3`
currently takes a search result or artifact and runs both targets.
[Tune comparison implementation](../../lib/tune/pipeline/compiler.ex)

Add one opt-in provider test independently of the Jido example. Replay one
synthetic RAG row through `Faithfulness` and `ContextPrecision`. Use one
configured judge model, an explicit test key, a short deadline, a small
managed-call budget, and disabled retries. Check score ranges, recorded judge
calls, returned token usage, and the stop reason. Keep exact score assertions
in the scripted suite. Exclude the live test from default CI and document the
manual command for a release check. For a later live GEPA experiment, reuse
the opt-in setup and measure against a held-out split.
[Current judge tests](../../test/tune/judge_scores_test.exs)

### 2. Add shared eval features only where host code repeats

- **Paired replay.** If a second suite needs the same join, let Tune compare
  two evaluated snapshots by stable case ID. Reuse the existing per-metric
  deltas, coverage, and row errors. Reject duplicate IDs and make absent
  observations visible. Keep storage and the release rule in the host.
- **Agent scores.** Start with ordered tool names and arguments under a narrow
  input contract. Use a deterministic outcome check when the host can verify
  the result. Consider one reference-based goal judge when the outcome needs
  interpretation. Add tool-call F1 or order-independent matching when a suite
  needs partial credit or can run independent tools in any order.
- **Retrieval from a live run.** Both shipped RAG scores read contexts from
  the case input. If a suite evaluates a retriever change, it needs the
  contexts returned by each runner. Try a custom scorer first. Consider one
  explicit context extractor if this repeats.
- **Repeatable reports.** Decide what identity a saved comparison must carry
  for its case set, scorer versions, and judge model. Start with what the
  example needs for a fair comparison.

[Tune comparison evidence](../../lib/tune/comparison.ex) ·
[Tune scores](../../lib/tune/scores/) ·
[Ragas agent metrics](https://docs.ragas.io/en/latest/concepts/metrics/available_metrics/agents/)

### 3. Test trace-informed GEPA with one named instruction

First try the existing `Tune.Program` path with a named instruction and a
score that returns concise evidence about the missed expectation. If the host
cannot run and score the same agent through that path, prototype one narrow
evaluator callback. The host accepts a candidate instruction and a case,
executes the agent, and returns a score with a bounded, redacted trace summary.
Use the existing validation and budget paths. Keep the current scalar
selector and one proposal per iteration for the first test. Report target,
judge, and proposal work separately. The host enforces limits for calls it
owns.

Compare the baseline against the learned instruction on cases that reflection
never saw. Check a critical case for regression. Build a scripted proof first
so an exact failure is easy to reproduce. Measure live behavior separately
under an approved call budget. This is the review point for a more general
candidate or evaluator API.
[Tune reflection loop](../../lib/tune/optimizers/reflective.ex) ·
[GEPA core API](https://gepa-ai.github.io/gepa/api/core/optimize/)

### 4. Make expensive searches recoverable once runs justify it

Start with checkpoints after completed iterations. Preserve the candidate pool,
lineage, random state, and budget counters. Validate the target, data, and score
configuration on resume. Keep checkpoint state separate from deployment
artifacts. A scripted restart should match an uninterrupted run. If interrupted
work can repeat, report which work may repeat and how the host counts it.

Measure cost before expanding search. Add a per-case evaluation counter if
users need to compare runs under the same metric budget. Track actual latency,
calls by role, tokens, and holdout results. Consider an evaluation cache only
when its key can identify the candidate, dataset split, case, and evaluator.
Consider parallel proposals or grouped evaluation when the timings show that
proposal or rollout latency dominates.
[GEPA checkpoint behavior](https://gepa-ai.github.io/gepa/guides/faq/) ·
[GEPA parallel proposals](https://gepa-ai.github.io/gepa/guides/parallel-proposals/)

## Gaps and ideas to revisit

| Area | Current limit in Tune | Evidence that would justify more work |
| --- | --- | --- |
| Eval metrics | Two built-in RAG judges. Context recall, response relevancy, semantic similarity, factual correctness, noise sensitivity, multimodal scores, and rubric judges need custom scorers. | Several suites need the same scoring contract and reference behavior. |
| Eval datasets and calibration | Tune consumes existing cases. It has no synthetic test-set generator, annotation workflow, or built-in judge alignment. | A concrete need for portable interchange or reusable alignment math. Keep dataset generation and labeling with the host. |
| DSPy optimizer behavior | Tune covers common instruction and demo workflows. MIPROv2 uses explicit budgets, its own categorical TPE, and proposals grounded in signatures and examples. It omits DSPy's auto presets and program or dataset summaries. | Reproduce a measurable gap on a representative task at a comparable budget. Check quality, calls, and seed variance before adding knobs. |
| DSPy program modules | DSPy ships ReAct, RLM, refinement, and other runtime modules. Tune has typed predictors and named calls that a host composes. | Keep loops, memory, code execution, and tool policy in the host. Consider a small stateless pattern after repeated use. |
| Adapter and model control | Tune adapters render and parse. Repair, extraction, and fallback are explicit application steps. The target adapter and model stay fixed in a program search. | Consider an explicit adapter option only if several users need the same pure render or parse behavior. Compare model variants through a host runner. |
| GEPA objectives | A selected score or weighted combination produces one scalar per case. This can drop a candidate that wins an independent objective. | Show a real held-out tradeoff that a weighted run loses. Try an opt-in per-objective or per-case-objective frontier with a defined winner policy. |
| GEPA policies | Fixed parent selection, one component per proposal, strict minibatch admission, full validation, and a disjoint common-ancestor merge. No seeded parity with upstream. | Compare a fixed scripted run and a live task before adding a policy hook, improved merge, or partial validation. |
| GEPA scale | No durable resume, evaluation cache, parallel proposals, grouped evaluator, ComBEE, or external experiment tracker. | Start with checkpoints and measured budgets. Add concurrency based on latency and add reflection aggregation when long traces exceed a useful prompt size. Send reports through host callbacks. |
| Optimize Anything | Tune evolves one declared text or JSON value through a program. The operator supplies the seed and merge stays disabled. | Consider a standalone evaluator, named components, or seedless search only if a host cannot use the one-value path. Leave additional engines and code execution outside the first scope. |
| Training and composition | Tune can search settings for a training loop. It provides no supervised fine-tuning, GRPO, trainer process, or prompt-and-weight pipeline. | Keep backend and job lifecycle in the host. Use the runner to score trained results. |
| Playbook and deployment | Tune can learn a bounded list of lessons and export learned parameters. Portable whole programs, online memory, staged promotion, audit, and rollback are host work. | Consider richer data provenance when a concrete deployment requires it. Keep the host's promotion decision and program code outside artifacts. |

[Tune compatibility](../../guides/compatibility.md) ·
[Tune MIPROv2](../../lib/tune/optimizers/mipro_v2.ex) ·
[DSPy optimizers](https://github.com/stanfordnlp/dspy/blob/main/docs/docs/learn/optimization/optimizers.md) ·
[DSPy modules](https://dspy.ai/current/api/modules/) ·
[DSPy program persistence](https://dspy.ai/current/tutorials/saving/) ·
[GEPA Optimize Anything](https://gepa-ai.github.io/gepa/api/optimize_anything/optimize_anything/) ·
[Ragas metrics](https://docs.ragas.io/en/latest/concepts/metrics/available_metrics/) ·
[Ragas test generation](https://docs.ragas.io/en/latest/concepts/test_data_generation/rag/)

## Host responsibilities

The host owns agent lifecycle, fresh state and fixtures, tools and permissions,
side effects and recovery, trace capture and redaction, report storage, domain
rubrics, human labels, synthetic data, and release decisions. It also owns
model configuration and limits for calls outside Tune's control. Tune can
accept a bounded view of this evidence without owning a trace system or
taking a dependency on the runtime that produced it.

## Open questions for the next review

1. Does the first external suite need a shared saved-run comparison API, or is
   the host join sufficient?
2. Which two domain cases prove that trace evidence improves an instruction
   missed by an answer-only score?
3. Which provider and call ceiling should the opt-in smoke test use?
4. After the first GEPA run, what limits value most: time lost on restart,
   scalar selection, full validation cost, or serial proposals?
