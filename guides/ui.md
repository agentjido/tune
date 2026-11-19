# Local Workbench

The workbench is an experimental local web page for Tune. Use it to preview a
prompt, evaluate a study, tune it, compare the winner with its baseline on
held-out rows, and download the artifact. It binds to `127.0.0.1` and keeps
all studies, runs, and artifacts in memory.

This walkthrough makes no model calls. It previews the built-in example
prompt, then runs an application recipe whose target is plain Elixir code.

## Install and start

Tune declares Phoenix Playground as an optional dependency. Add
`{:phoenix_playground, "~> 0.1.9"}` next to `{:tune, "~> 0.5.0"}` in your
project's `deps/0`. A project that does not use the workbench does not need
Phoenix.

Fetch the dependencies and start the workbench:

```sh
mix deps.get
mix tune.ui
```

The task prints `Tune workbench is available at http://localhost:4000` and
opens a browser. Choose another port, or skip the browser:

```sh
mix tune.ui --port 4100 --no-open
```

Stop the workbench with `Ctrl+C` twice. Stopping the VM discards every study
and run.

## Preview a prompt

1. On the dashboard, select **Load example**. Tune creates a grounded
   question-answering study with two training rows, one validation row, and
   one test row, and opens its **Preview** page.
2. Read **Rendered messages**. They show the instructions and the first saved
   input exactly as the target model would receive them.
3. Read **Equivalent pipeline** to see the `Tune` calls that the study
   stands for.

The preview makes no model call. Do not start an evaluation of this example
unless you mean to: it targets `openai:gpt-4o-mini` and sends real requests
through your ReqLLM configuration.

## Add an offline recipe

A recipe is trusted application code that turns a stored study into a normal
`%Tune{}` pipeline. The browser never sends module names or code. This recipe
chooses the stock level that triggers a reorder. Its runner is plain Elixir,
so it needs no model and no credentials.

```elixir
defmodule MyApp.ReorderRecipe do
  @moduledoc "Chooses the stock level that triggers a reorder."
  @behaviour Tune.UI.Recipe

  @impl true
  def id, do: "reorder_threshold"
  @impl true
  def label, do: "Reorder threshold"
  @impl true
  def description, do: "Choose the stock level that triggers a reorder."
  @impl true
  def default_config, do: %{"threshold" => 5}
  @impl true
  def preview_input(_study), do: {:error, :no_prompt}

  @impl true
  def build(study) do
    pipeline =
      %{threshold: study.config["threshold"]}
      |> Tune.new(run: fn settings, input -> input["stock"] < settings.threshold end)
      |> Tune.data(study.data)
      |> Tune.score(:correct, fn tune_case, reorder? ->
        if reorder? == tune_case.expected["reorder"], do: 1, else: 0
      end)
      |> Tune.vary(threshold: [5, 10, 20])
      |> Tune.search(:grid)

    {:ok, pipeline}
  end
end
```

Register the recipe in `config/dev.exs` with
`config :tune, Tune.UI, recipes: [MyApp.ReorderRecipe]`, then run
`mix tune.ui`. An application that starts the workbench itself can pass
`recipes: [MyApp.ReorderRecipe]` to `Tune.UI.start/1` instead.

## Create the study and add rows

1. Select **New study**. Choose **Reorder threshold** under **Recipe**, name the
   study, and select **Create study**.
2. Open **Data**. Rows from the JSON editors arrive with string keys, which is
   why the recipe reads `input["stock"]`. Paste these rows into the validation
   editor:

   ```json
   [
     {"id": "v1", "input": {"stock": 3}, "expected": {"reorder": true}},
     {"id": "v2", "input": {"stock": 8}, "expected": {"reorder": true}},
     {"id": "v3", "input": {"stock": 15}, "expected": {"reorder": false}}
   ]
   ```

   Paste these rows into the test editor:

   ```json
   [
     {"id": "t1", "input": {"stock": 2}, "expected": {"reorder": true}},
     {"id": "t2", "input": {"stock": 9}, "expected": {"reorder": true}},
     {"id": "t3", "input": {"stock": 30}, "expected": {"reorder": false}}
   ]
   ```

3. Select **Save data**. Each split accepts up to 1,000 rows. **Saved row
   preview** lists what the study stored.

## Evaluate the baseline

Open **Run** and select **Start evaluation**. The workbench evaluates the
first split that has rows, in the order test, validation, train. Here it uses
the test rows with the default threshold of 5.

The run report shows:

- **Status**, **Mode**, and **Selected score**. The selected score is
  `0.6666666666666666`, two of three rows.
- The **Result** badges: `0 calls`, `0 tokens`, and the stop reason. The calls
  badge counts model calls that Tune could see, including judge calls. A
  recipe with a plain Elixir runner reports none.
- A metric table with the mean and coverage for `correct`.
- **Row results**: one line per row with its execution status, score,
  expected value, and output. Open **Row t2 details** to see the input and full
  output. For model-backed recipes this section also lists **Model responses**
  and any **Errors**.
- **Run evidence**: the study, recipe, split, row counts with fingerprints,
  declared scores, and declared models with non-secret configuration.

Row `t2` scores zero. Stock 9 is above the threshold of 5, so the baseline
does not reorder.

## Tune and compare on held-out rows

1. Return to **Run** and select **Start tuning**. The grid search scores each
   threshold on the validation rows and selects `10`.
2. On the completed search report, find **Compare with baseline**. Choose
   `test` under **Dataset split** and submit.

The comparison runs the original configuration and the winner on the same
test rows. Its report shows calls and tokens for each side, then a metric
table with the baseline mean, winner mean, change, scored pairs, and
improved, regressed, tied, error, and unpaired counts:

```text
correct  maximize  0.6667  1.0  0.3333  3/3  1  0  2  0  0
```

The row table shows that `t2` improved and `t1` and `t3` tied. Open
**Outputs** on a row to see both outputs side by side.

## Download the artifact

The completed search report has an **Artifact** section. Select **Download
JSON** to save `<run id>.json`. The file holds the learned values, run
provenance, and a fingerprint of the target it was tuned for. The download is
one line of compact JSON; it is formatted here for reading:

```json
{
  "parameters": {
    "threshold": 10
  },
  "provenance": {
    "best": {
      "coverage": null,
      "eligible": true,
      "id": "1",
      "mean": null,
      "selected_score": 1.0
    },
    "calls": {},
    "complete": true,
    "datasets": {},
    "kind": "generic",
    "models": {},
    "optimizer": ":grid",
    "seed": null,
    "settings": {},
    "source": "Tune.tune/1",
    "stop_reason": "completed",
    "usage": {
      "input": 0,
      "output": 0,
      "total": 0
    }
  },
  "target_fingerprint": "174a7a9230ee2dc4e929105f283c57f8838c2c98d19b95b74f68b6c21ded1b19",
  "version": 1
}
```

Save the artifact before you stop the VM. Nothing in the workbench survives a
restart. Load it later with `Tune.Artifact.decode/1` and `Tune.load/2`; see
[Artifacts](artifacts.md).

## Check the recipe without the browser

The workbench runs ordinary Tune calls. You can check a recipe in a test or
IEx by building the same pipeline from a `Tune.UI.Study` value:

```elixir
rows = fn list ->
  for {id, stock, reorder?} <- list,
      do: %{"id" => id, "input" => %{"stock" => stock}, "expected" => %{"reorder" => reorder?}}
end

study = %Tune.UI.Study{
  id: "reorder",
  name: "Reorder",
  recipe: "reorder_threshold",
  config: MyApp.ReorderRecipe.default_config(),
  data: %{
    validation: rows.([{"v1", 3, true}, {"v2", 8, true}, {"v3", 15, false}]),
    test: rows.([{"t1", 2, true}, {"t2", 9, true}, {"t3", 30, false}])
  }
}

{:ok, pipeline} = MyApp.ReorderRecipe.build(study)
{:ok, result} = Tune.tune(pipeline)
{:ok, comparison} = Tune.compare(pipeline, result, split: :test)

IO.inspect(result.best.parameters, label: "winner")
IO.inspect(Enum.sort(comparison.metrics.correct.counts), label: "test rows")
```

```text
winner: %{threshold: 10}
test rows: [improved: 1, tied: 2]
```

## Other pages

- **Studies** lists every study. Each study has **Settings**, **Data**,
  **Preview**, and **Run** pages.
- **Artifacts** lists artifacts from completed tuning runs.
- **Settings** in the main navigation scans the local ReqLLM configuration and
  catalog. It makes no model calls and shows no credential values. Select
  **Use in study** on a model to start a study with it.
- The **Saved responses** recipe scores saved answers with faithfulness and
  context-precision judges. Those judges call the configured model.

## Limits

- State is in memory and is lost when the VM stops.
- The workbench listens on `127.0.0.1` only. It has no user accounts or remote
  access.
- Data input is JSON, limited to 1,000 rows per split.
- Page styles load from a CDN.
- Model calls use the application's ReqLLM configuration.
- Automated tests drive the pages in-process. They do not start a listener or
  test browser behavior.
