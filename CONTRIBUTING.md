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

Maintainers can use the [release procedure](https://github.com/mikehostetler/tune/blob/main/docs/releasing.md)
to verify a release commit, publish to Hex, and check the published package.
