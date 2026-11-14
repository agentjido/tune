# Tune

Typed and optimizable language-model programs built on ReqLLM.

Define typed predictors, compose them with ordinary Elixir code, inspect the
exact prompts, evaluate on explicit datasets, tune instructions,
demonstrations, and declared JSON values for one fixed model configuration,
and load the learned parameters back into application code.

```elixir
{:ok, predictor} =
  Tune.Predictor.new(
    signature: [
      instructions: "Classify the support ticket.",
      inputs: [ticket: Zoi.string()],
      outputs: [label: Zoi.enum(["billing", "bug", "other"])]
    ]
  )

model = [model: "openai:gpt-4o-mini", adapter: Tune.Adapter.Chat]

{:ok, result} = Tune.run(predictor, %{ticket: "I was charged twice"}, model: model)
result.output
#=> %{"label" => "billing"}
```

## What is included

- Typed JSON-compatible fields with Zoi; one validated output contract.
- Pure Chat, JSON (text or structured), and XML prompt adapters.
- Composition through the `Tune` behaviour and `Execution`, with
  managed call, step, and deadline limits.
- Evaluation with numeric or score/feedback metrics, explicit failure
  scores, and eligibility rules.
- Fifteen optimizer targets: LabeledFewShot, BootstrapFewShot,
  BootstrapFewShotWithRandomSearch, BootstrapFewShotWithOptuna (native TPE),
  KNNFewShot, COPRO, SignatureOptimizer, MIPROv2, InferRules, SIMBA, GEPA,
  Avatar, Ensemble, Playbook, and Optimize.Anything.
- Versioned parameter artifacts with allowlisted provenance.
- A pure prepare/finish boundary for host inference paths.

No Python runtime is used. Image, audio, and file inputs, weight training,
and program structure search are not included.

## Guides

- [Programs, predictors, and evaluation](guides/programs.md)
- [Optimizers](guides/optimizers.md)
- [Compatibility and differences](guides/compatibility.md)
- [Parameter artifacts](guides/artifacts.md)
- [Host integration](guides/host_integration.md)

Start with the [runnable examples](examples/README.md):

```sh
mix run examples/inspect_prompts.exs
MIX_ENV=test mix run examples/offline_qa.exs
```

The first script renders and parses supplied replies without a model call.
The second shows two-step QA, evaluation, optimization, prompt inspection,
and artifact reload with local scripted replies. The examples guide also
covers local Ollama models and an explicit live-provider comparison.

## Boundaries

ReqLLM owns provider requests, responses, structured-output handling,
transport retries, and caching. This package owns signatures, prompt
formats, demonstrations, named parameters, evaluation, optimization, and
artifacts. The application owns its code, model configuration, credentials,
and runtime policy. Jido is an optional host; this package does not depend
on it.

## Local checks

```sh
mix deps.get
mix quality
mix test
```

`mix quality` runs formatting, warnings-as-errors compilation, Credo
(strict), and Dialyzer. Tests are offline: model replies are scripted
through `Req.Test` behind the public ReqLLM API. No provider key is needed.

## Status

Local, unpublished library. No license has been chosen and the package has
not been published.

The local project was renamed from `req_llm_program` to `tune`. Use the Mix
application `:tune` and the `Tune` namespace. Existing callers must update
their aliases, struct names, dependency paths, and commands. The live example
opt-in variable is now `TUNE_LIVE`. See the artifact guide for version 1
compatibility.

Combining this package with `jido_eval` and `jido_evolve` remains a design
proposal. Nx and Axon integration is also a future possibility. This rename
does not add those capabilities or change the current scope.
