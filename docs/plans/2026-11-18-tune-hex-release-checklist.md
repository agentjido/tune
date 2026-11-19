# Tune 0.5.0 Hex release checklist

Checked on 2026-11-18. The first version is **0.5.0** and the Git tag is
**v0.5.0**. If the release is a beta, describe that in the release notes.
Hex consumers will see `0.5.0` as a normal SemVer version.

The owner selected Apache-2.0, public source, and the existing Hex API key
method used by ReqLLM. Tune's release workflow uses that method. Workload
Identity can follow the wider Jido publishing migration.

Local checks for the `0.5.0` candidate passed on Elixir 1.18.4 / OTP 27 and
Elixir 1.20.4 / OTP 29, with 328 tests on each pair. The quality checks,
generated docs, quick-start examples, and Hex dependency audit passed on the
current pair. Fresh source consumers passed with and without the workbench.
Actionlint passed for both workflows. A redacted scan found no credential
patterns in the local Git history. Hex 2.7.0 built the tarball and passed
the publish dry run. Two fresh Mix consumers passed against the unpacked
tarball. The offline guide examples passed from the same tarball. The
first GitHub Actions run remains a release gate.

A temporary Git repository verified the release tag check with simulated
GitHub CI results. The check accepted a matching tag on `main` only when
the latest CI run for that commit passed. It rejected a bad tag, a missing
changelog entry, a commit outside `main`, and missing or failed CI results.

## Readiness before local release prep

| Area | ReqLLM | Tune |
| --- | --- | --- |
| Public release | Public source, tagged GitHub releases, and published Hex packages. The latest observed release was v1.31.0. | Private source, no Git tags or GitHub releases, and a public Hex lookup for `tune` returned 404. |
| License | Apache-2.0 in the repository and Hex metadata. | License choice pending. The repository has no `LICENSE` file and `mix.exs` has no `licenses` entry. |
| CI | The Jido reusable CI workflow checks pull requests and main. It supports a test matrix, quality checks, docs, dependency checks, and a Hex dry run. | Zero GitHub Actions workflows. The local worktree passed 328 offline tests, `mix quality`, and `mix docs`. |
| Release | The Jido reusable release workflow prepares or publishes releases, supports dry runs, and receives `HEX_API_KEY` from the caller. | No workflow or package owner setup has been established. Current `mix.exs` says `0.1.0`. |
| Package | Explicit file list, license and maintainer metadata, documentation and changelog links, and source links tied to the version tag. | Package metadata contains a GitHub link. Tune relies on the default Hex file list. No Tune tarball install has been verified. |
| Consumer checks | Published package and docs with an established release history. | A separate Mix app passed offline evaluate, tune, and compare from source on Elixir 1.18.4 / OTP 27 and Elixir 1.20.4 / OTP 29, without Phoenix Playground. |
| Maintenance | Changelog, security policy, contribution guide, issue and PR templates, and Dependabot. | README and guides are in place. The repository has no matching release and maintenance files. |

Tune's local checks were on the working copy based on `6ec5afe`, with 37
modified tracked files and three untracked files. The checked worktree is
larger than the commit currently on GitHub.

[ReqLLM CI](https://github.com/agentjido/req_llm/blob/main/.github/workflows/ci.yml) ·
[ReqLLM release workflow](https://github.com/agentjido/req_llm/blob/main/.github/workflows/release.yml) ·
[ReqLLM package configuration](https://github.com/agentjido/req_llm/blob/main/mix.exs) ·
[ReqLLM v1.31.0](https://github.com/agentjido/req_llm/releases/tag/v1.31.0) ·
[ReqLLM on Hex](https://hex.pm/packages/req_llm)

## 1. Choose what ships

- [x] Select Apache-2.0 and add the license text and its SPDX identifier.
- [x] Review the package contents for third-party assets. The workbench uses
      native HTML meters and loads its MIT-licensed styles from a CDN.
      The tarball contains no copies of these browser assets.
      [DaisyUI license](https://github.com/saadeghi/daisyui/blob/master/LICENSE) ·
      [Tailwind CSS license](https://github.com/tailwindlabs/tailwindcss/blob/main/LICENSE)
- [ ] Confirm the intended Hex owner. Review GitHub history, then make Tune's
      source public when authorized. The GitHub API returned HTTP 403 for
      Tune's branch rules under the private-repository plan.
- [ ] Review the full worktree and select the files for the release PR. Include
      source files that the selected changes need, such as `lib/tune/run_limits.ex`
      if the run-limit changes ship. Keep `study-spike.html` as a design artifact
      outside the package. State which parts of the optional workbench are
      experimental.
- [x] Define `@version` as `"0.5.0"` and use it for Mix and ExDoc source links.
      Describe Tune as an Elixir evaluation and search library. Keep the README
      install requirement, package version, changelog, and tag in agreement.
- [x] Create `CHANGELOG.md` with a first-release entry. The release workflow
      takes the GitHub release notes from the entry for the current tag.

## 2. Make the package useful on its own

- [x] Add explicit Hex metadata in `mix.exs`. Include the approved license,
      maintainer, description, and links for docs, source, changelog, and support.
      Set ExDoc's source ref to the matching release tag.
- [x] Add a Hex file allowlist. Start with `lib`, `mix.exs`, `.formatter.exs`,
      `README.md`, `LICENSE`, and `CHANGELOG.md`. Include any required runtime
      assets and public guides that users should have in the download. Include
      examples only if the package claims to ship runnable examples.
- [x] Check the unpacked tarball against the allowlist. Verify runtime assets,
      the optional workbench entry point, and the license. Check that the file
      list excludes `.env`, local agent skills and lock files, the HTML spike,
      build output, and local fixture outputs.
- [x] Add a quick start that a downstream app can run after installing
      `{:tune, "~> 0.5.0"}`. Include one plain Elixir study and one scripted
      prompt example. Explain how to opt into Phoenix Playground and how to
      run `mix tune.ui`. State the workbench's loopback and in-memory behavior.
- [x] Fix the example links that lead back to the generated README.
      Check that generated links name the release tag and the right paths.
- [ ] Open the examples and source links once the public release tag exists.
- [x] Document supported Elixir/OTP pairs, optional dependencies, and the public
      API and artifact format that beta users can rely on. Record limitations
      for each feature that users can reach.

## 3. Put the checks in GitHub CI

- [x] Add `.github/workflows/ci.yml` for pull requests and pushes to `main`.
      Add `merge_group` if Tune uses a merge queue. Reuse Jido's CI workflow
      only after checking its inputs and jobs against Tune's requirements.
      Set Tune's Elixir/OTP pairs explicitly because the libraries have
      different Elixir minimums.
- [ ] Run `mix test` on Elixir 1.18.4 / OTP 27 and Elixir 1.20.4 / OTP 29 as the
      initial verified pairs. Run `mix quality` and `mix docs` on the current
      pair. Use Linux runners, scripted responses, and public Hex dependencies.
      Keep provider credentials out of CI. Cache deps and Dialyzer data by
      runner, toolchain, and lockfile.
- [ ] Run the dependency checks used by the shared CI where they apply.
      Run `mix hex.audit` with a Hex version that checks both advisories and
      retirements. Verify a fresh resolution of the advertised dependency
      ranges. Add one job that consumes Tune without optional deps and one
      that installs the workbench with Phoenix Playground.
- [x] Add package checks to CI and the release preflight. Save the package
      manifest and checksum. Run the Hex publish dry run with the pinned Hex
      version in the release preflight.
- [x] Run the package preflight locally. Install the unpacked tarball in fresh
      Mix apps with and without the workbench. Run an offline evaluation and
      search. Execute the getting-started examples from the package.
- [ ] Make the resulting CI checks required for `main`. Restrict who can
      create or change release tags if the GitHub plan supports tag rules.
      Give normal CI read permissions. Pin actions and reusable workflows
      to full commit SHAs. Keep release credentials in the publish job only.

[Shared Jido CI](https://github.com/agentjido/github-actions/blob/v5/.github/workflows/jido-ci.yml) ·
[Hex build](https://hexdocs.pm/hex/Mix.Tasks.Hex.Build.html) ·
[Hex publish dry run](https://hexdocs.pm/hex/Mix.Tasks.Hex.Publish.html) ·
[GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)

## 4. Ship v0.5.0 and make later releases repeatable

- [x] Add `.github/workflows/release.yml` with a read-only dry run and a
      publish job that uses a GitHub environment.
- [ ] Set up the `hex-publish` environment with
      reviewer and ref restrictions where the plan permits. Serialize the
      release jobs for the package. Use the supported GitHub environment or
      an owner-operated publish step if the private-repo plan lacks that gate.
- [x] Require an exact `vMAJOR.MINOR.PATCH` tag for the stable release path.
      Check that its commit is on `main`, that the latest CI run for that SHA
      passed, and
      that the tag matches `mix.exs`. Use the tag SHA for checkout, preflight,
      package build, and release notes. If the publish command builds the
      tarball again, compare its file manifest with the preflight manifest.
      Test that a mismatched tag or failed preflight blocks publishing.
- [ ] Make the existing Hex publish key available as `HEX_API_KEY` to
      Tune's publish job. Confirm the key can create the first public package
      under the intended Hex owner. Recheck name availability and ownership
      at publish time.
- [ ] Verify the first release on Hex and HexDocs. Install `0.5.0` from Hex
      in a fresh Mix app and repeat the offline smoke check. Publish the GitHub
      Release with notes, the published checksum, and links to Hex and HexDocs.
      If Hex succeeds and the GitHub step fails, repair the GitHub release
      using the same tag and the existing Hex version.
- [ ] Migrate to Hex Workload Identity when the wider Jido migration is
      approved. Bind it to the
      final GitHub repository, exact release workflow file, and environment.
      A public GitHub repo requires an environment in the Hex configuration.
      A private repo needs its numeric repository ID. Use a compatible,
      pinned Hex version, grant `id-token: write` to the publishing job, and
      let `mix hex.publish` obtain the short-lived token. Keep GitHub release
      writes in the job that needs them. Use a publish job with explicit
      Workload Identity support. ReqLLM's current wrapper passes an API key.
- [x] Document the regular release sequence. Merge the version and notes PR,
      tag its green commit, approve publish, and check Hex, HexDocs, GitHub,
      and the fresh install. Make retries check existing release state first.
      For a bad package, document who can retire it and how to ship a fix
      under a new patch version.

[Hex publishing](https://hex.pm/docs/publish) ·
[Hex Workload Identity](https://hex.pm/docs/workload-identity) ·
[GitHub release environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

## 5. Set up routine maintenance

- [x] Add `CONTRIBUTING.md` with local checks, the supported runtime pairs,
      and the release procedure. Add a short PR template for behavior, docs,
      and offline test evidence.
- [x] Add `SECURITY.md` with supported release lines and a private reporting
      path.
- [ ] Enable private vulnerability reporting and the issue tracker in GitHub.
- [x] Add Dependabot for Mix and GitHub Actions. Keep dependency updates in
      PRs that run the same checks. Assign owners for Hex, GitHub settings, and
      release recovery so later versions have a clear path to publication.

**First release is ready when** the exact `v0.5.0` commit has green required
checks, the package manifest and install checks pass, and the owner approves
the publish job. Keep the same checks and API key release method for later
versions until the Workload Identity migration.
