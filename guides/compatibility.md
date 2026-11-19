# Compatibility and boundaries

Tune follows documented behavior from DSPy and Imp. It uses an Elixir API and
an Elixir runtime. Exact seeded parity and every upstream option are not goals.
Tune uses no Python runtime.

## Prompt formats

| Format | Tune behavior | Main difference |
| --- | --- | --- |
| Chat | Field markers, field list, demonstrations, and a completion marker | Uses JSON Schema types and strict JSON values |
| JSON | Object skeleton, ordered demonstrations, text mode, and structured mode | No repair and no automatic format fallback |
| XML | Schema-directed elements and array items | Bounded parser with no entities, DTDs, attributes, or namespaces |

All adapters are pure. They render and parse. They do not call a model, retry,
repair, or select another adapter.

## Prompt and example search

Tune includes the documented behavior of these prompt and example targets:

- LabeledFewShot
- BootstrapFewShot
- BootstrapFewShotWithRandomSearch
- BootstrapFewShotWithOptuna
- KNNFewShot
- COPRO
- SignatureOptimizer
- MIPROv2
- InferRules
- SIMBA
- GEPA
- Avatar
- Ensemble
- Playbook
- Anything

Tune uses native Elixir search and local random state. Its Optuna-style search
uses a small categorical TPE implementation. Its GEPA-style search uses model
call budgets and one selected score. Tune does not reproduce Python object
models, package options, tracking services, or exact random sequences.

## Selected evaluation behavior

Tune replays saved answers from an Enumerable and records independent metric
results, coverage, judge evidence, and failed attempts. Use
`Tune.Evaluation.start/3` with your Task supervisor for asynchronous runs.
The progress callback lets an application publish events, write reports, or
store results. Parse JSONL or CSV with an application stream. See
[Programs and evaluation](programs.md#replay-saved-responses).

ReqLLM owns provider transport and retries. Tune counts logical inference
attempts and records the usage that ReqLLM returns.

## Selected evolutionary behavior

Tune evaluates an application-supplied population, or samples named spaces
around an initial value. It supports whole-genome variation, custom parent
selection, deterministic random state, tournament selection, elitism, and
generation snapshots. A search can stop on a target score, lack of improvement,
evaluation limits, deadline, or cancellation. The progress callback delivers
generation snapshots during execution. See
[Search strategies](optimizers.md#evolve-a-seeded-population).

## Nx and Axon

Tune has no runtime dependency on Nx or Axon. An application runner can receive
Nx tensor streams and can return tensors, Axon models, loop state, or other
opaque terms. Tune does not inspect those terms.

A score callback must convert a final scalar tensor to a finite Elixir number.
The application owns Axon model construction, loops, backends, devices, model
parameters, and serialization. Tune tunes configuration values. It does not
train model weights.

Artifacts accept only JSON-compatible learned parameters and provenance. They
reject tensors, Axon models, functions, processes, ports, and references.

## Fixed boundaries

- Zoi checks Tune-owned input fields when they enter a workflow. Saved replay
  rows are checked as the evaluator reads them. The workbench uses the same row
  schema when it saves a study.
- Paired comparison requires nonblank UTF-8 case IDs and checks the selected
  cases for duplicates before target work starts. Ordinary evaluation keeps
  its existing ID rules.
- Tune checks rules that depend on multiple fields or records, such as score
  range order, artifact versions, and matching program fingerprints. Adapters
  check their own options. ReqLLM resolves models and checks provider options.
- ReqLLM owns model transport, responses, structured output, and retries.
- Tune owns programs, prompts, scores, evaluation, selection, search, and
  learned-value artifacts.
- The application owns tools, agent loops, side effects, credentials,
  persistence, training, and deployment.
- Jido can consume Tune, but Tune does not depend on Jido.

## Workflow comparisons

- **DSPy.** Tune uses Zoi-typed Elixir programs, explicit data splits, and
  separate target, teacher, and proposal roles. The
  [DSPy workflow lessons](https://github.com/mikehostetler/tune/tree/v0.5.0/examples/01_dspy) test the optimizer
  contracts and candidate evidence with deterministic transport.
- **Imp.** Imp exposes module macros, agent loops, and supervised agents.
  Tune uses ordinary Elixir functions for program composition and leaves
  agent state, tools, and supervision with the host.
- **Jido Evolve.** Jido Evolve ships operator modules for binary, text,
  permutation, and parameter genomes. Tune supports named variation spaces
  and application-owned genome callbacks. Its generation snapshots report
  complete and interrupted populations. See the
  [evolution lessons](https://github.com/mikehostetler/tune/tree/v0.5.0/examples/03_evolution).
- **Jido Eval.** Jido Eval exposes its own dataset types and metric harness.
  Tune replays saved `input` and `output` rows from an Elixir Enumerable. It
  reports independent metrics and judge calls. The host owns parsing,
  transcript rules, report delivery, and persistence. See the
  [evaluation lessons](https://github.com/mikehostetler/tune/tree/v0.5.0/examples/04_eval).

### Automatic feedback-driven mutation

Jido Evolve passes fitness feedback to operators that declare
`mutate_with_feedback/3`. Tune's generic mutation callback receives the genome
and random state. Tune reports score feedback as evidence, and GEPA uses
feedback during proposal generation. Automatic transfer of evaluation feedback
to a generic genetic operator is a separate compatibility item.
