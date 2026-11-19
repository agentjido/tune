# Release Tune

Tune uses the shared Jido CI checks and the same `HEX_API_KEY` secret name
as ReqLLM. Its Release workflow verifies the tagged commit, tests the
package, and checks the Hex checksum before it creates a GitHub release.

## Set up the repository

Enable private vulnerability reporting and the required CI checks on
`main`. Restrict creation and changes to version tags to release maintainers.

Use the GitHub environment `hex-publish`, restricted to version tags.
After the first release, create a Hex key with `publish:tune` for the
package and `api:read`. Add it as an environment secret. Run the command in
your own terminal and paste the key at the GitHub CLI prompt.

```sh
gh secret set HEX_API_KEY -R agentjido/tune --env hex-publish
```

## Record the first release

Hex already has `tune` version `0.5.0`. The published package files match
commit `b271f775aca0300b34f2a5e01d951ce15c7b5f66`. Use that commit for
the `v0.5.0` tag. Its workflow predates the `finalize` operation, so use
the changelog entry to create the first GitHub release from that tag.
Use a new patch version for later package changes.

## Publish a version

1. Update `@version` in `mix.exs` and add the matching changelog entry in a
   pull request. Check that the docs and examples use the release version.
2. Merge the PR and wait for the CI run on the exact commit on `main`.
   Create and push the matching annotated version tag when authorized.
3. Open the Release workflow, select the tag, and run it with operation
   `dry-run`. Inspect the manifest and checksum in the workflow artifact.
4. Run the same workflow for the same tag with operation `publish`. If Hex
   stages the release, open the approval link in the publish job log.
   Compare the checksums and approve it on Hex with 2FA while the job waits.
5. Open the version on Hex, its HexDocs, and its GitHub release. Check
   the install instruction and the links in the generated start page.

For example, use these commands for `v0.5.1`.

```sh
gh workflow run release.yml --ref v0.5.1 -f operation=dry-run
gh workflow run release.yml --ref v0.5.1 -f operation=publish
```

If the publish job times out while it waits for Hex approval, check the
release on Hex before you rerun the workflow. After approval, run
`operation=finalize` for the same tag to verify the package and create the
GitHub release. For a local publish from a new tag, use the Hex version
pinned in the workflow so the archive checksum matches. For a defective
package, have the Hex owner retire the affected version and ship a fix
under a new patch version.

Hex Workload Identity can replace the API key after the package exists
and the Jido projects are ready to make that change.

[Hex publishing](https://hex.pm/docs/publish) ·
[Hex Workload Identity](https://hex.pm/docs/workload-identity)
