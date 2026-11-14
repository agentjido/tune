# Compatibility and differences

Documented behavior is the compatibility target. Exact seeded parity and
every upstream option are not goals.

## Sources

- DSPy, commit `4e9db7a83e71e4c36315a2402ae7ffd0c6493404`, cited as the 3.5.0
  release. Note: that commit's `pyproject.toml` declares `version="3.4.1"`;
  the release tag and this commit should be reconciled before a release claim.
- `gepa`: DSPy declares `gepa>=0.1.4,<0.2.0`. No exact version is pinned by
  DSPy; record the resolved version when comparing against a Python run.
- Optuna: DSPy declares `optuna>=3.4.0` (optional extra). The TPE behavior
  follows Optuna's documented independent categorical `TPESampler`.
- Imp at `748317df` for Imp-specific targets (SignatureOptimizer scope,
  Playbook, Optimize.Anything boundary).

No Python runtime is used, bundled, or started.

## Formats

| Format | Implemented | Differences |
| --- | --- | --- |
| Chat | `[[ ## field ## ]]` markers, field list, completion marker, demo message pairs, response hint | JSON type names and JSON Schema instead of Python annotations; non-string values decoded as strict JSON, no repair or literal evaluation; markers recognized with irregular spacing around `##`; each output marker must appear exactly once |
| JSON | object skeleton, ordered demo objects, text and structured modes | no `json_repair`; no automatic structured-to-text fallback; extra keys ignored, missing keys rejected |
| XML | schema-directed elements, nested objects as child elements, arrays as `<item>`, raw unescaped text | not a general XML parser: no entities, DTDs, attributes, or namespaces; string values containing their own closing tag are rejected before rendering; bounded size and depth |

## Optimizers

| Target | Implemented rules | Deliberate differences |
| --- | --- | --- |
| LabeledFewShot | up to `k` complete labeled rows per predictor, seeded sampling without replacement | unscored build; incomplete rows skipped per predictor |
| BootstrapFewShot | labeled teacher, current-row demo exclusion, whole-trajectory acceptance with `accept_score`, intermediate demos, labeled fill | rounds do not vary temperature or bypass caches; a limited build is an error |
| …WithRandomSearch | zero-shot, labeled, unshuffled, shuffled bootstraps with random sizes; full validation each | scored on explicit validation |
| …WithOptuna | categorical TPE after startup trials, full validation per trial, cached repeats | chooses whole bootstrapped sets per predictor instead of one demo index; native TPE without Optuna's RNG or multivariate mode |
| KNNFewShot | per-input nearest training rows, teacher bootstrap from neighbors, counted calls | supplied pure vectorizer or bag of words; no embedding service |
| COPRO | breadth proposals per predictor, depth rounds with scored attempts, coordinate updates | validation scoring; one typed call returns a list |
| SignatureOptimizer | one named predictor's instruction | Imp's target; in DSPy it is a deprecated COPRO alias |
| MIPROv2 | bootstrapped sets, grounded instruction proposals, joint categorical TPE, minibatches, periodic full promotion | training minibatches; no auto presets, dataset summarizer, or program-code summary |
| InferRules | rules from bootstrapped demos appended to instructions; original and bootstrapped baselines selectable | rules from a shuffled demo view per candidate |
| SIMBA | minibatches, softmax program sampling, gap-ranked rows, demo and rule strategies, final validation | variation from program sampling, not model temperature; weak rows borrow a better in-batch trajectory |
| GEPA | Pareto parent selection, round-robin components, minibatch acceptance, reflection with feedback, merge, lineage | budgets are model calls; no presets, tracking, or multi-objective framework |
| Avatar | positive/negative split by bounds, contrastive feedback, scoped rewrite, validation | no agent runtime or tools; failures are always negative |
| Ensemble | members, majority vote with earliest-member ties, custom reducer, seeded size | an ordinary program constructor, not a search |
| Playbook | lesson proposals from training traces, schema and growth limits, validation comparison | no separate promotion/audit workflow or checkpoints |
| Optimize.Anything | GEPA-style search over one declared value, schema checked on every proposal | evaluated through a normal program and metric, not a separate evaluator interface |

Reports separate observed scores from these algorithm descriptions.
Offline tests prove each row's decision rules with scripted model replies;
they are not measurements of model quality.

## Runtime

The declared Elixir floor is `~> 1.18`. See the package progress record for
the runtime combinations actually checked.
