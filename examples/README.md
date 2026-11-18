# Tune offline examples

The examples form a learning path and an offline integration suite. The
numbered folders are the inventory. Each chapter links to its lessons. Each
lesson has a runner, expected results, and tagged tests that use the same
workflow.

Run from the Tune repository root.

```sh
mix deps.get
mix test.examples --warnings-as-errors
```

Run a chapter or one lesson by path.

```sh
mix test.examples test/examples/03_evolution --warnings-as-errors
mix test.examples test/examples/04_eval/04_02_retrieval --warnings-as-errors
MIX_ENV=test mix run examples/04_eval/04_02_retrieval/demo.exs
```

All numbered runners use local fixtures or scripted ReqLLM replies. They run
without provider credentials or live calls.

| Chapter | Workflows |
| --- | --- |
| [01 DSPy workflows](01_dspy/README.md) | Typed output, demonstrations, prompt search, and voting |
| [02 GEPA and reflective search](02_gepa/README.md) | Feedback, per-case strengths, lineage, and typed parameters |
| [03 Evolution and configuration search](03_evolution/README.md) | Grid search, genetic operators, model training, and interruption |
| [04 Evaluation](04_eval/README.md) | Saved data, judge metrics, supervised runs, and release gates |
| [05 Application workflows](05_application/README.md) | OTP service deployment and the workbench |

See [example instructions](AGENTS.md) for the layout and verification rules.
See [workflow compatibility](../guides/compatibility.md) for the DSPy,
GEPA, Jido Evolve, and Jido Eval boundaries.
