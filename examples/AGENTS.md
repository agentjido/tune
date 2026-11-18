# Tune example instructions

These instructions apply to `examples/` and the matching files under
`test/examples/`. They follow the Jido Core example guide for Tune's Mix
project and public API.

## Purpose

Use the examples as a learning path and an offline integration suite. Teach
one main public contract or application pattern in each lesson. Show the normal
path and the failures, recovery, or cleanup that matter to the same workflow.
Extend an existing example when it can teach the behavior clearly.

Use ordinary application code for parsing, storage, process ownership, release
decisions, and other host responsibilities. Use public Tune APIs for studies,
scoring, search, comparison, runtime calls, and artifacts. Record gaps that
need a core change. Keep HTN code and fixtures in the owning project.

## File layout

```text
examples/
  support/
  NN_chapter/
    README.md
    support/
    NN_MM_lesson/
      README.md
      example.ex
      demo.exs
      fixtures/
      support/
test/examples/
  NN_chapter/
    NN_MM_lesson/
      example_test.exs
```

The folder tree is the inventory. Keep numbers, chapter READMEs, and links
aligned. Use the chapter number in each lesson ID. Keep reader-facing source
with its lesson. Keep fixtures beside the code that uses them. Put shared
code in chapter support when two or more lessons use it. Use top-level support
for code that two or more chapters use. Give shared modules specific names
under `Tune.Examples.Support`. Avoid dependencies on private code in other
lessons.

## README contract

Give each lesson a short README with the problem, the result, the main
contract, and a suggested reading order. Include exact runner and test commands,
expected output or state, and the important failure or cleanup behavior.
Include a **Limits** section. For advanced lessons, add **Core Fit and Gaps**
and identify which gaps belong to the application, ecosystem, documentation,
or Tune core. Link the source, tests, and relevant fixtures and support. Use
previous and next links when the order matters.

Give each chapter a brief README with the lessons in order. Keep the main
README focused on setup, the chapter inventory, and the verification commands.

## Offline runners and tests

- Run the same workflow from `demo.exs` and its tagged ExUnit tests. Keep
  `@moduletag :example` on each module under `test/examples/`.
- Run through real Tune and ReqLLM code with scripted Req replies at the
  transport boundary. Runners need no provider credentials or network access.
- Use fixed seeds, bounded searches, explicit model-call ceilings, and
  deterministic fixtures. On error, make the runner exit with a failure status.
- Use public behavior and reports as evidence. Use explicit synchronization
  and monitor cleanup when tests start concurrent work. Leave application
  configuration as it was before the test.
- Keep policies, model options, and secrets separate. Persist learned values
  through Tune artifacts and load them into fresh trusted application code.
- Explain what the example proves. Use targeted core tests for edge cases
  outside the lesson.

## Verification

Run a focused test with
`mix test.examples test/examples/NN_chapter/NN_MM_lesson --warnings-as-errors`.
Run the documented script from the Tune root. After changes to shared support
or to more than one chapter, run `mix test.examples --warnings-as-errors`, the
full `mix test` suite, and `mix quality`. Check links and lesson IDs after a
move. Keep pass totals out of the inventory.
