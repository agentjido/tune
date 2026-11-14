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

Tune includes the useful evaluation cases that guided `jido_eval`:

- enumerable data;
- retained row results and errors;
- named numeric scores and text feedback;
- count, mean, minimum, maximum, and coverage;
- structured faithfulness and context-precision judges;
- bounded row concurrency, row timeout, deadline, and call accounting.

Tune does not include the `jido_eval` dataset protocol, component registry,
async run registry, permanent supervisor, cache service, retry wrapper,
middleware, reporters, stores, broadcasters, processors, CSV adapter, or JSONL
adapter. Applications can use normal Elixir streams, Tasks, supervisors, files,
and storage libraries.

ReqLLM owns provider transport and transport retries. Tune does not add another
retry policy.

## Selected evolutionary behavior

Tune includes the useful generic-search cases that guided `jido_evolve`:

- deterministic local random state;
- bounded populations and generations;
- tournament selection and elitism;
- mutation and crossover;
- evaluation limits, deadline, cancellation, and retained failed candidates.

Tune does not include old entity, evolvable, mutation, or crossover protocol
families. It does not include an install task, a second configuration layer, or
an `evolve` stream facade. Variation behavior belongs to small `Tune.Space`
implementations. The public workflow stays in the Tune pipeline.

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

- ReqLLM owns model transport, responses, structured output, and retries.
- Tune owns programs, prompts, scores, evaluation, selection, search, and
  learned-value artifacts.
- The application owns tools, agent loops, side effects, credentials,
  persistence, training, and deployment.
- Jido can consume Tune, but Tune does not depend on Jido.
