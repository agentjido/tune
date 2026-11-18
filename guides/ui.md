# Local workbench

Tune includes an optional multi-route web workbench. It uses Phoenix
Playground. The workbench keeps all studies, runs, and artifacts in memory.
It binds to `127.0.0.1` and does not store credentials.

The workbench uses the default DaisyUI components and Tailwind browser build
from jsDelivr. The UI needs network access to load its styles. Tune and the
workbench routes still run without those assets. The workbench follows the
operating system light or dark preference and updates when that preference
changes. It does not include a separate theme switcher.

The workbench uses one small ApexCharts hook for score, score comparison, and row
status charts. The dashboard lists scores for individual
runs. Compare only runs that use the same metric and data.

## Install

Add Phoenix Playground to the host application with Tune:

```elixir
def deps do
  [
    {:tune, "~> 0.1"},
    {:phoenix_playground, "~> 0.1.9"}
  ]
end
```

Tune declares Phoenix Playground as an optional dependency. A host that does
not use the workbench does not need Phoenix.

Start the workbench:

```sh
mix tune.ui
```

Use another port, and do not open a browser:

```sh
mix tune.ui --port 4100 --no-open
```

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

The dashboard can load a grounded QA example. It creates a structured prompt
study with training, validation, and test rows, then opens prompt preview. It
does not make a model call.

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

The Settings scan uses `ReqLLM.available_models/0`, `ReqLLM.Doctor.run/0`, and
completed workbench runs. It is read-only. It does not call a model and it
does not show credential values. A successful response records the model that responded at that time. It does not prove that the provider is reachable now.
Known models appear as suggestions in study model fields.

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
- Model calls use the application's ReqLLM configuration.
- Automated Tune tests do not call a live model provider.
