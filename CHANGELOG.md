# Changelog

<!-- changelog -->

## [0.5.1](https://github.com/agentjido/tune/compare/v0.5.0...v0.5.1) (2026-11-19)




### Bug Fixes:

* optimizer: record effective merge settings in Anything artifacts by mikehostetler

* runtime: count tokens from all recorded replies by mikehostetler

* deps: remove Tune's direct Req dependency by mikehostetler

### Documentation:

* readme: explain Tune use cases and capabilities by mikehostetler

* guides: add 19 Livebooks and update seven Markdown guides by mikehostetler

## 0.5.0

First public beta of Tune.

- Evaluate Elixir functions, structured prompts, and saved answers with named scores.
- Search Elixir parameters and prompt examples. Compare the winner with its baseline on a held-out dataset.
- Use Chat, JSON, or XML adapters with ReqLLM. Preview rendered messages before inference.
- Export learned values as versioned JSON artifacts and apply them in the host app.
- Try the experimental local workbench for study setup, run reports, and artifact downloads.
