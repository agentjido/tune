# Tune Workbench

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The primary users are Elixir developers who use Tune and ReqLLM to evaluate
or improve structured LLM prompts.

## Product Purpose

The workbench lets a developer set up a study, preview the messages that go to
the model, run an evaluation or search, and inspect the results in a browser.
Success means the developer can see what ran, which data and model it used,
and which rows passed or failed.

## Operating Context

Tune is an Elixir library. The optional workbench runs locally with Phoenix
Playground. Start it with `mix tune.ui`. The browser uses the host application's
ReqLLM configuration for model calls. The tested local workflow uses LM Studio.

A study groups the prompt, model, and data. The workbench can evaluate on
labeled rows, score saved answers, and tune a program. A completed search can
be compared with its baseline on a selected split. A run records data
fingerprints, declared models, and models that returned responses.

## Capabilities and Constraints

- Bind the workbench to loopback and keep credentials in the host application.
- Keep studies, runs, and artifacts in memory for the life of the workbench.
- Preserve the simple DaisyUI interface and its light and dark themes.
- Let developers inspect the exact prompt and run evidence. Keep advanced
  setup available near the controls it affects.
- Compare scores only when runs use the same metric and data.

## Evidence on Hand

- [Workbench guide](guides/ui.md)
- [Offline workbench example](examples/05_application/05_02_workbench/README.md)
- [Workbench flow tests](test/tune/workbench_flows_test.exs)

## Product Principles

- Make study setup, data entry, evaluation, and row results easy to find.
- Show the model, data, and call limit before a run starts.
- Keep reproducibility evidence available in completed reports.
