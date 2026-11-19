# Release Tune

Tune uses the shared Jido CI checks and the same `HEX_API_KEY` secret name
as ReqLLM. GitHub Actions creates the version tag, builds and tests the
package, publishes to Hex and HexDocs, and creates the GitHub Release.
The maintainer starts each operation in GitHub Actions and approves
staged publication when Hex requires it.

## Set up the repository

Enable private vulnerability reporting and the required CI checks on
`main`. If the repository uses tag rules, allow the Release workflow to
create version tags.

Use the GitHub environment `hex-publish`, restricted to version tags.
After the first release, create a Hex key with `publish:tune` for the
package and `api:read`. Add it as an environment secret. Run the command in
your own terminal and paste the key at the GitHub CLI prompt.

```sh
gh secret set HEX_API_KEY -R agentjido/tune --env hex-publish
```

## First release status

Hex has `tune` version `0.5.0`. The published package files match
`b271f77`, and the public `v0.5.0` tag points to `c9642f1`. There is
no GitHub Release for `v0.5.0`. See the
[0.5.0 checklist](plans/2026-11-18-tune-hex-release-checklist.md) for
the evidence and open tag decision.

Use the [0.5.1 beta checklist](plans/2026-11-19-tune-0.5.1-beta-checklist.md)
to verify the full GitHub-to-Hex publish path.

## Publish a version

1. Update `@version` in `mix.exs` and add the matching changelog entry in a
   pull request. Check that the docs and examples use the release version.
2. Merge the PR and wait for CI on `main`. Use `dry-run` on `main` with
   the intended `tag_name` to check a release candidate before tagging.
3. Run the Release workflow on `main` with operation `prepare` and enter
   the intended `tag_name` when you have approval to create the tag.
   The workflow checks the exact CI commit, version, changelog, and package
   before it creates the annotated tag.
4. Run the Release workflow on the new tag with operation `dry-run`.
   Inspect the manifest and checksum in the workflow artifact.
5. After approval to publish, run the Release workflow on the same tag
   with operation `publish`. If Hex stages the release, use the approval
   link in the publish job log. Compare the checksums and approve on Hex
   with 2FA while the job waits.
6. Check the completed workflow. It verifies the checksum in the Hex API
   and the downloaded archive, checks HexDocs, and installs the published
   version with and without the optional workbench. It creates the GitHub
   Release after those checks pass.

For example, use these commands for `v0.5.1`.

```sh
gh workflow run release.yml -R agentjido/tune --ref main -f operation=dry-run -f tag_name=v0.5.1
gh workflow run release.yml -R agentjido/tune --ref main -f operation=prepare -f tag_name=v0.5.1
gh workflow run release.yml -R agentjido/tune --ref v0.5.1 -f operation=dry-run
gh workflow run release.yml -R agentjido/tune --ref v0.5.1 -f operation=publish
```

If the publish run fails, check Hex before you retry. When the version
is on Hex, run `finalize` on the same tag to verify the published package
and create the GitHub Release. When the version is absent, correct the
failure and retry the `publish` operation on GitHub Actions. For a
defective package, have the Hex owner retire the affected version and
ship the fix under a new patch version through the Release workflow.

Hex Workload Identity can replace the API key after the package exists
and the Jido projects are ready to make that change.

[Hex publishing](https://hex.pm/docs/publish) ·
[Hex Workload Identity](https://hex.pm/docs/workload-identity)
