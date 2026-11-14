# Run the examples

Run these commands from the `tune` directory.

## 1. Inspect a typed prompt

```sh
mix run examples/inspect_prompts.exs
```

This example defines a support ticket classifier with a string input, an enum
output, and a boolean output. It renders the same predictor through Chat, JSON,
and XML. Each format shows the system prompt, one demonstration, and the current
input. It then validates a supplied reply with `Predictor.finish/2`.

No model request is made. Edit the instructions, fields, or demonstration and run
the script again to see the exact prompt change. The model configuration selects
the adapter; the predictor holds the task and its demonstrations.

## 2. Run, evaluate, optimize, and reload a two-step program

```sh
MIX_ENV=test mix run examples/offline_qa.exs
```

The [grounded QA program](grounded_qa.ex) uses ordinary Elixir code to call two
named predictors. `extract` selects facts from supplied passages. `answer` uses
those facts and returns an answer with source identifiers.

The script shows this sequence for each adapter:

1. Evaluate the baseline on the test rows.
2. Use a separate teacher to build demonstrations from training rows.
3. Select a candidate with explicit validation rows and a limit of 64 model calls.
4. Evaluate the selected program on the test rows.
5. Print both steps and the rendered answer prompt.
6. Write a JSON artifact to the temporary directory.
7. Load the artifact into fresh program code and run it again.

Every request goes through ReqLLM to a local `Req.Test` handler. The existing
reply helpers live under `test/support`, so this script uses `MIX_ENV=test`.
It does not run ExUnit or contact a provider. No credentials are needed.

The target handler returns a correct answer only when the request contains a
demonstration. The teacher always returns a correct answer. Thus the expected
test score is `0.0 -> 1.0`, with `Reload matches optimized program: true`.
These values demonstrate control flow. They are not evidence of model quality.
Token totals from these handlers are also supplied data.

Training, validation, and test rows are declared separately. The call limit of
64 applies to optimization only. Each test evaluation has its own limit of 8;
the final reloaded run has a limit of 2. The target configuration remains fixed
during each optimization run. This optimizer does not need a proposal model.

## 3. Use local models

Start Ollama and install the target and teacher models. Then run:

```sh
OLLAMA_TARGET=lfm3:latest OLLAMA_TEACHER=qwen3.8:27b \
  mix run examples/ollama_examples.exs
```

This existing script runs a classifier, two-step QA, a baseline comparison, and
artifact reload. It contacts the local Ollama server. Results depend on the
installed models. An optimized prompt can score lower on separate test rows.

## 4. Compare provider models

The [live comparison](live_comparison.exs) accepts repeated `--target` options.
Set the provider credentials that ReqLLM requires, then run it explicitly:

```sh
TUNE_LIVE=1 mix run examples/live_comparison.exs -- \
  --target openai:gpt-4o-mini --teacher openai:gpt-4o-mini --max-calls 200
```

This command contacts the configured provider and can incur charges. The call
limit applies to each optimization run. Baseline and final test evaluations are
separate calls. Compare scores, parse success, and usage for each target and
adapter. There is no automatic choice of model or adapter.
