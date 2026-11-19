# Compatibility

This reference maps DSPy, GEPA, Jido Evolve, Jido Eval, and Nx or Axon
workflows to Tune entry points. Tune follows the documented workflow of each
source. It does not copy their object models, options, or exact random
sequences, and it runs no Python.

The "Tested by" column names the offline lesson whose tests exercise that
workflow with scripted replies or local fixtures. Codes such as `01_01` refer to
the numbered lessons under
[`examples/`](https://github.com/agentjido/tune/tree/v0.5.0/examples) in the
source repository; they are not part of the Hex package. A workflow is
listed as available only when a lesson or contract test covers it.

## Prompt formats

All three adapters render a prompt and parse a reply. None of them calls a
model, retries, repairs output, or falls back to another adapter.

| Format | Tune module | Difference that affects your code | Tested by |
| --- | --- | --- | --- |
| Chat field markers | `Tune.Adapter.Chat` | Field types are described with JSON Schema; field values must be valid JSON where the type is not a string. | `01_01` |
| JSON object | `Tune.Adapter.JSON` | `adapter_options: [mode: :text]` or `[mode: :structured]` is required. No JSON repair, no automatic switch between modes. | `01_01` |
| XML elements | `Tune.Adapter.XML` | Bounded parser with no entities, DTDs, attributes, or namespaces. | `01_01` |

Signatures use Zoi schemas in place of Python type annotations. Validated
outputs are maps with string keys.

## Prompt and demonstration search

Pass the strategy name to `Tune.search/3`. The target program, its adapter,
and its model configuration stay fixed during search. Teacher and proposal
models are separate `teacher:` and `proposal:` options to `Tune.new/2`.

| DSPy or GEPA optimizer | Tune strategy | Tested by |
| --- | --- | --- |
| LabeledFewShot | `:labeled_few_shot` | `01_02` |
| BootstrapFewShot | `:bootstrap_few_shot` | `01_03` |
| BootstrapFewShotWithRandomSearch | `:bootstrap_few_shot_random_search` | `01_04` |
| BootstrapFewShotWithOptuna | `:bootstrap_few_shot_optuna` | `01_04` |
| KNNFewShot | `:knn_few_shot` | `01_05` |
| SignatureOptimizer, COPRO | `:signature_optimizer`, `:copro` | `01_06` |
| MIPROv2 | `:mipro_v2` | `01_07` |
| InferRules | `:infer_rules` | `01_08` |
| SIMBA | `:simba` | `01_09` |
| AvatarOptimizer | `:avatar` | `01_10` |
| Playbook-style lessons | `:playbook` | `01_11` |
| Ensemble | `Tune.Ensemble`, or `:ensemble` to search members | `01_12`; `:ensemble` in `test/tune/ensemble_test.exs` |
| GEPA | `:gepa` | `02_01`, `02_02` |
| Optimize Anything | `:anything` | `02_03` |

Differences that affect Elixir code:

- Data splits are explicit. Pass `train:`, `validation:`, and `test:` to
  `Tune.data/2`, and compare on a split you choose with `Tune.compare/3`.
- Random state is local and seeded with `Tune.limit/2` (`seed:`). Tune does
  not reproduce Python random sequences.
- The Optuna-style search uses a small native categorical TPE.
- GEPA uses model-call budgets and one selected score.
- Learned values leave the run as a `Tune.Artifact`, not a pickled program.

## Evaluation and replay

| Jido Eval or DSPy workflow | Tune entry point | Tested by |
| --- | --- | --- |
| Score saved answers | `Tune.replay/2` with an Enumerable of `input` and `output` rows | `04_01` |
| Grounding and context precision judges | `Tune.Scores.Faithfulness`, `Tune.Scores.ContextPrecision` | `04_02` |
| Stream a large file | Parse in the application; pass the stream or a zero-arity factory | `04_03` |
| Multi-turn transcripts | Application-defined scores over ordered turns | `04_04` |
| Background runs and progress | `Tune.evaluate/2` in a host task, or `Tune.Evaluation.start/3`; `on_progress:` | `04_05`; `start/3` in `test/contracts/saved_evaluation_test.exs` |
| Paired release decision | `Tune.compare/3` on the same holdout cases | `04_06` |
| Evaluate live code | `Tune.new/2` with `run:`, then `Tune.evaluate/2` | `03_01`, `04_06` |

Tune records each score independently, with coverage, failed rows, and judge
calls. It has no dataset types of its own. The host owns parsing, transcript
rules, report delivery, and persistence.

## Evolution and configuration search

| Jido Evolve workflow | Tune entry point | Tested by |
| --- | --- | --- |
| Exhaustive finite search | `Tune.vary/2` with ranges or lists, `Tune.search(:grid)` | `03_01` |
| Seeded string population | `Tune.search(:genetic, ...)` with application crossover and mutation | `03_02` |
| Binary genome with feasibility | `:genetic` with application operators | `03_03` |
| Permutation genome, custom parent selection | `:genetic` with permutation-safe crossover | `03_04` |
| Generation snapshots and interruption | `:genetic` with `on_progress:` and `cancel:` | `03_06` |

Jido Evolve ships operator modules for each genome type. In Tune the
application supplies genome callbacks, and Tune supplies selection, elitism,
stop rules, and snapshots. Tune reports score feedback as evidence, and GEPA
uses it to propose changes. A generic genetic operator receives the genome and
random state, not evaluation feedback.

## Nx and Axon

Tune has no runtime dependency on Nx or Axon. Tested by `03_05` and
`test/contracts/nx_axon_compatibility_test.exs`:

- A runner can receive Nx tensor streams and return tensors, Axon models, or
  loop state. Tune keeps them as opaque output.
- A score must return a finite Elixir number. Convert a scalar tensor with
  `Nx.to_number/1`.
- Tune tunes configuration such as layer width or learning rate. It does not
  train weights. The application owns models, loops, backends, and devices.
- `Tune.dump/1` rejects tensors and Axon models in learned parameters.

## Run-time boundaries

| Owner | Responsibilities |
| --- | --- |
| Tune | Programs, prompts, scores, evaluation, selection, search, artifacts. |
| ReqLLM | Model resolution, provider transport, responses, structured output, retries. |
| Host | Tools, agent loops, side effects, credentials, persistence, training, deployment. |

Tune has no Jido dependency. A Jido host passes its run function as a runner
and keeps its own inference controls. See [Host Integration](host_integration.md).

What can cross each boundary (tested by
`test/contracts/artifact_test.exs` and the Nx and Axon contract test):

| Value | Through a runner | In a JSON artifact |
| --- | --- | --- |
| Case input and output, any Elixir term | Yes | No |
| Tensors and Axon models | Yes, as opaque output | Rejected by `Tune.dump/1` |
| Functions, PIDs, references | Yes, as opaque output | Rejected (functions in provenance are tested) |
| JSON-compatible learned parameters | Yes | Yes |
| Demonstrations and instructions of a program | Yes | Yes, checked against the program fingerprint on load |
| Non-secret model names, adapter, dataset counts and fingerprints | Yes | Yes, as provenance |
| Credentials, request options, `api_key` | Host-owned | Rejected |
| Module names or code | Host-owned | Rejected on decode |

`Tune.Artifact.decode/2` creates no atoms from artifact data and enforces
byte and entry limits. `Tune.load/2` applies nothing when the artifact does not
match the fresh target.
