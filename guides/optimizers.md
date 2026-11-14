# Optimizers

```elixir
{:ok, optimized, report} =
  Tune.optimize(program,
    optimizer: {Tune.Optimizers.MIPROv2, accept_score: 1.0},
    trainset: train,
    valset: validation,
    metric: &MyApp.metric/2,
    model: target,
    teacher: teacher,
    proposal: proposal,
    max_model_calls: 500,
    seed: 0
  )
```

## Shared rules

- The target configuration and adapter are fixed for the run. Teacher and
  proposal configurations are separate and required only when an algorithm
  uses them; the target is never copied into those roles.
- Optimizers change task parameters only: instructions, demonstrations, and
  declared JSON values.
- Searches require explicit training and validation data. There is no
  automatic split. Validation rows with the same inputs as a training row are
  a setup error; semantic overlap is not detected. `:testset` is rejected.
  Exact duplicate training rows are removed once and counted.
- An algorithm that calls models requires `:max_model_calls`. Every managed
  call (target, teacher, proposal, including failures and evaluation) is
  counted before dispatch. On exhaustion the best complete eligible candidate
  is returned with `complete?: false` and `stop_reason: :budget_exhausted`, or
  `Error.Optimization.Failed` with the report when none completed.
- A candidate is returnable only after a complete, eligible validation pass.
  Minibatch scores guide search but never become the result. Ties keep the
  earlier candidate.
- Random choices use local seeded state. A seed does not change provider
  output; control provider caching through request options.
- Bootstrapped trajectories are accepted only when the whole program succeeds
  and, with a metric, scores at least `accept_score`.

## Inventory

| Target | Module | Calls models | Data | Roles |
| --- | --- | --- | --- | --- |
| LabeledFewShot | `Optimizers.LabeledFewShot` | no | train | — |
| BootstrapFewShot | `Optimizers.BootstrapFewShot` | yes | train | teacher |
| BootstrapFewShotWithRandomSearch | `Optimizers.BootstrapFewShotWithRandomSearch` | yes | train, val | teacher |
| BootstrapFewShotWithOptuna | `Optimizers.BootstrapFewShotWithOptuna` | yes | train, val | teacher |
| KNNFewShot | `Optimizers.KNNFewShot` → `Tune.KNN` | at run time | train | teacher (at run time) |
| COPRO | `Optimizers.COPRO` | yes | train, val | proposal |
| SignatureOptimizer | `Optimizers.SignatureOptimizer` | yes | train, val | proposal |
| MIPROv2 | `Optimizers.MIPROv2` | yes | train, val | teacher, proposal |
| InferRules | `Optimizers.InferRules` | yes | train, val | teacher, proposal |
| SIMBA | `Optimizers.SIMBA` | yes | train, val | proposal |
| GEPA | `Optimizers.GEPA` | yes | train, val | proposal |
| Avatar | `Optimizers.Avatar` | yes | train, val | proposal |
| Ensemble | `Tune.Ensemble.new/2` | no (construction) | — | — |
| Playbook | `Optimizers.Playbook` | yes | train, val | proposal |
| Optimize.Anything | `Optimizers.Anything` | yes | train, val | proposal |

Each module's documentation states its algorithm and options.
[Compatibility](compatibility.md) lists sources and deliberate differences.

Reports record every candidate with its validation summary and lineage,
calls per role, provider-reported token totals, dataset fingerprints,
portable optimizer settings, and algorithm notes (for example TPE trials,
SIMBA steps, GEPA iterations and pool).
