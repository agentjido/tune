# Tune

## Scope and authority

This is an independent Mix library in the ReqLLM monofolder. The first-release
scope in `docs/plans/` is implemented; progress is recorded in `docs/progress/`.
Implementation does not authorize commits, pushes, a license choice, Hex
package builds, publication, or paid provider calls. Ask for each explicitly.
Local Ollama examples are allowed when requested.

## Design rules

- Follow the ReqLLM patterns in the sibling `req_llm/` repository.
- Normalize public input once. Use one canonical value shape inside each boundary.
- Use explicit structs, pattern matching, small functions, and immutable updates.
- Use Zoi for new data contracts and Splode for package-owned errors when needed.
- Preserve ReqLLM responses and errors. Do not copy its provider logic.
- Add dependencies only when code uses them. Declare direct dependencies explicitly.
- Keep runtime model configuration and credentials out of learned parameters.
  Artifacts may contain explicitly allowed non-secret configuration provenance.
  Never serialize raw runtime options, credentials, functions, or response structs.
- Keep composition in ordinary Elixir code. Do not add a macro DSL or workflow engine.
- Keep adapters pure: render prompts and parse replies. Repair and extraction
  are explicit program steps. ReqLLM owns transport retries.
- Keep target configuration and adapter fixed during optimization. Teacher and
  proposal configurations are separate and explicit.
- For the current scope, require no Python runtime for installation, compilation,
  execution, or default checks. Do not bundle or start Python workers. Optional
  training backends must follow this rule and stay outside the prompt core.
- Keep Jido optional. Preserve its inference controls at the host integration boundary.
- Do not write comments inside function bodies.
- Add tests for behavior and invariants. Do not add tests that only mirror code.

## Checks

Run Mix commands from this directory. Use `mix quality` and `mix test`.
The default checks must need no credentials and must make no live provider calls.
Place behavior tests under `test/tune/` and contract tests under
`test/contracts/`. Keep test helpers under `test/support/`.

## Documentation

Keep package plans in `docs/plans/`. Keep the implementation plan stable during
execution; record temporary progress elsewhere. Preserve unrelated work in all
sibling repositories.
