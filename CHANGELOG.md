# Changelog

## 0.5.1

Second public beta of Tune.

- Add 19 Livebooks and update seven Markdown guides. The examples cover API use, tuning, genetic search, retrieval, and agent evaluations.
- Record `use_merge: false` in `:anything` reports and artifacts to match the optimizer's behavior.
- Fill `prediction.usage` with the provider token counts from all recorded model replies, including replies that fail parsing.
- Remove Tune's direct Req dependency.

## 0.5.0

First public beta of Tune.

- Evaluate Elixir functions, structured prompts, and saved answers with named scores.
- Search Elixir parameters and prompt examples. Compare the winner with its baseline on a held-out dataset.
- Use Chat, JSON, or XML adapters with ReqLLM. Preview rendered messages before inference.
- Export learned values as versioned JSON artifacts and apply them in the host app.
- Try the experimental local workbench for study setup, run reports, and artifact downloads.
