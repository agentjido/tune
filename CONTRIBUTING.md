# Contributing

Run these checks from a Tune checkout.

```sh
mix deps.get
mix test
mix quality
mix docs
```

The default tests use scripted responses. For a change to an example, run
`mix test.examples`. Add a test for changes to public behavior. Include the
commands and results in the pull request. Follow the design rules in
`AGENTS.md`.

The initial CI pairs are Elixir 1.18.4 with OTP 27 and Elixir 1.20.4 with
OTP 29. Use a versioned sample to reproduce issues with artifacts. Replace
credentials, private prompts, and user data with sample values.

## Commits and changelog

Use Conventional Commit messages such as `fix(runtime): record token usage`
or `docs(guides): add an evaluation example`. Use `feat` for additions to
the public API and `!` or a `BREAKING CHANGE` footer for breaking changes.
CI checks new commit messages. If you squash a pull request, use a
Conventional Commit subject for the squash commit.

Run `mix install_hooks` from the primary checkout to enable the optional
local commit-message check. GitOps generates `CHANGELOG.md` for the
release pull request. Describe user-facing changes in commit messages.

Maintainers can use the [release procedure](https://github.com/agentjido/tune/blob/main/docs/releasing.md)
to verify a release commit, publish to Hex, and check the published package.
