# Local workbench

Use the experimental workbench to preview a prompt, evaluate a study, or
compare a tuned program with its baseline. The workbench binds to
`127.0.0.1` and keeps studies, runs, and artifacts in memory.

## Install

Add Phoenix Playground to the host application with Tune:

```elixir
def deps do
  [
    {:tune, "~> 0.5.0"},
    {:phoenix_playground, "~> 0.1.9"}
  ]
end
```

Tune declares Phoenix Playground as an optional dependency. A host that does
not use the workbench does not need Phoenix.

Fetch the dependencies and start the workbench.

```sh
mix deps.get
mix tune.ui
```

Use another port, and do not open a browser:

```sh
mix tune.ui --port 4100 --no-open
```

## Preview a study without a model call

1. Select **Load example** on the dashboard. Tune creates a question-answering
   study with two training rows, one validation row, and one test row.
2. Read **Rendered messages** to check the instructions and the selected
   input. Open **Data** to inspect the expected answers.
3. Open the study's **Settings** to inspect the target model and call limit.
   The example uses `openai:gpt-4o-mini`. You can change it to a model that
   your application has configured.

## Evaluate, tune, and compare

This procedure sends requests through your application's ReqLLM configuration.

1. Open the example study's **Run** page. Check the data, target model, and
   call limit. For a baseline-only run, select **Start evaluation**.
2. On **Run**, select **Start tuning**. The example adds the two
   labeled training answers as demonstrations and evaluates them on
   validation data.
3. On the completed search, open **Compare with baseline**. Choose `test`
   under **Dataset split** and submit the comparison. This scores both prompts
   on the same held-out row. Inspect the output and score for that row.
4. Select **Download JSON** on the search run before you stop the workbench
   if you want to keep the selected prompt.

## Find a model

Open **Settings** in the main navigation. Search by model or provider name,
then expand the provider. Open **Model capabilities** to narrow the catalog
results. Select **Use in study** to start a new study with that model.

The scan reads local ReqLLM configuration, catalog data, and completed
workbench runs. It makes no model calls and shows no credential values.
A response from a completed run is evidence for that run.

## Routes

| Route | Purpose |
| --- | --- |
| `/` | Show study and run totals. |
| `/studies` | List studies. |
| `/studies/new` | Start a structured prompt study or saved-answer evaluation. |
| `/studies/:id` | Inspect one study. |
| `/studies/:id/settings` | Change its prompt, models, adapter, search, and limits. |
| `/studies/:id/data` | Add training, validation, and test rows. |
| `/studies/:id/preview` | Inspect the rendered prompt without a model call. |
| `/studies/:id/run` | Start evaluation, search, or a comparison. |
| `/runs/:id` | Watch a run and inspect its result. |
| `/artifacts` | List artifacts from completed tuning runs. |
| `/settings` | Scan ReqLLM configuration and catalog inference availability. |
| `/runs/:id/artifact` | Download one versioned artifact as JSON. |

## Data and run evidence

The structured prompt recipe accepts rows with `inputs` and `labels` maps.
The saved responses recipe uses the Test rows editor. Paste rows with
`input`, `output`, and optional `id` and `expected`. For retrieval scores,
`input` contains `user_input` and `retrieved_contexts`. Choose the judge
model and a call limit. The workbench shows Faithfulness and Context
Precision results independently.

Use **Compare with baseline** on a completed search. Choose a dataset split.
The workbench uses the search's original recipe and configuration and the
currently selected dataset. The report shows metric changes, the number of
scored pairs for each metric, row outcomes, model calls, token use, and
incomplete results.

Each run records its split, declared scores, and non-secret model
configuration. The report shows the count and fingerprint of the selected
source rows and the effective cases after normalization. For program search,
the effective training cases have duplicates removed. For streamed evaluation,
the counts cover the rows read through the stop point. The report also shows
the models that returned responses. Edits to the study do not change this
evidence.

The data page shows row counts beside each JSON editor and a preview of saved
rows. The Test rows editor opens by default. The run page shows its model, data,
strategy, and call limit before execution. Completed runs show score and row
status charts; the full Elixir result stays in a collapsed section.

## Application recipes

The UI does not accept module names or executable code from the browser. An
application can add trusted recipe modules when it starts the UI:

```elixir
Tune.UI.start(recipes: [MyApp.TuneRecipe])
```

A recipe implements `Tune.UI.Recipe`. It converts stored UI data into a normal
`%Tune{}` pipeline. The application still owns code, provider credentials, and
runtime configuration.

## Limits

- State is lost when the VM stops.
- The UI has no user accounts or remote access.
- Data input is JSON and is limited to 1,000 rows per data role.
- Browser styles use CDN assets.
- Model calls use the application's ReqLLM configuration.
- Automated Tune tests do not call a live model provider.
