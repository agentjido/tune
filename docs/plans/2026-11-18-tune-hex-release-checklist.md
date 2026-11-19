# Tune 0.5.0 beta release checklist

Verified on 2026-11-19. Hex and HexDocs have the first public beta. The
public Git tag points to a different commit from the published package.
GitHub has no Release record for `v0.5.0`.

## What shipped

- [x] Publish `tune` version `0.5.0` under Apache-2.0. The source repository
  is public. [Hex release](https://hex.pm/packages/tune/0.5.0) ·
  [Source repository](https://github.com/agentjido/tune)
- [x] Ship evaluation for Elixir functions, structured prompts, and saved
  answers. Ship parameter and prompt search, paired comparisons on held-out
  data, Chat, JSON, and XML adapters, versioned JSON artifacts, and the
  optional experimental local workbench. [Published changelog](https://hexdocs.pm/tune/0.5.0/changelog.html)
- [x] Ship seven Markdown guides. They cover getting started, programs,
  optimizers, compatibility, artifacts, host integration, and the local
  workbench. [0.5.0 HexDocs](https://hexdocs.pm/tune/0.5.0/)
- [x] Verify the published checksum against the downloaded Hex archive.
  SHA-256 is `ad9f4da1566bb5d4b499510b373dd1f94f1c8ca4c2c5318695163671d5154626`.
  [Hex release metadata](https://hex.pm/api/packages/tune/releases/0.5.0)

## Git tag and GitHub Release

| Evidence | Result |
| --- | --- |
| Published Hex archive | All 122 packaged files match [`b271f775aca0300b34f2a5e01d951ce15c7b5f66`](https://github.com/agentjido/tune/commit/b271f775aca0300b34f2a5e01d951ce15c7b5f66). |
| Public `v0.5.0` tag | Points to [`c9642f107b01ac01d73666383cfd1ed88ddcd733`](https://github.com/agentjido/tune/commit/c9642f107b01ac01d73666383cfd1ed88ddcd733). Only 116 of the 122 packaged files match this commit. |
| GitHub CI | Passed on the tagged commit, including both runtime pairs, quality, docs, and package install checks. [CI run](https://github.com/agentjido/tune/actions/runs/44443905416) |
| GitHub Release workflow | The tag verification job passed. The Hex publish and GitHub Release jobs were skipped. [Dry run](https://github.com/agentjido/tune/actions/runs/44449945242) |
| GitHub Release record | `gh release view v0.5.0` returned `release not found`. [GitHub Releases](https://github.com/agentjido/tune/releases) |

The six files that differ are `CONTRIBUTING.md`, `README.md`, `SECURITY.md`,
`guides/compatibility.md`, `guides/optimizers.md`, and `mix.exs`. The Hex
archive still declares a direct `:req` dependency. The tagged commit removes
that dependency and changes the source URL to `agentjido/tune`.

- [ ] Decide with the release owner how to handle the public tag mismatch.
  Require explicit approval for any change to the public tag. If the owner
  approves a 0.5.0 GitHub Release, verify that its tag resolves to the source
  that matches the Hex archive before creating it.

## Pre-release checks

These results are from preparation on 2026-11-18. The GitHub results above
apply to the named commits and jobs.

- [x] Pass 328 tests on Elixir 1.18.4 with OTP 27 and Elixir 1.20.4 with OTP
  29. Pass the quality, docs, quick-start, and Hex dependency checks locally.
- [x] Pass actionlint for both workflows and a redacted credential-pattern
  scan of local Git history.
- [x] Build and inspect the tarball, and pass the publish dry run with Hex
  2.7.0. Run the offline examples and install the unpacked tarball in
  separate Mix apps with and without the optional workbench.
- [x] Test the tag guard in a temporary repository. It accepted a matching
  tag on `main` with passing CI. It rejected an invalid tag, a missing
  changelog entry, a commit outside `main`, and missing or failed CI.

The new guide set, bug fixes, and full GitHub-to-Hex publish check are on
the [0.5.1 beta checklist](2026-11-19-tune-0.5.1-beta-checklist.md).
