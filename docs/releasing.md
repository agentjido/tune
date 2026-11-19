# Release Tune

Tune uses the shared Jido CI checks. Its Release workflow uses the same
Hex API key method as ReqLLM. The workflow verifies a tag, publishes to
Hex, checks the published package, and creates the GitHub release.

## Set up the repository

Before the first release, review the repository history and make the
source public with owner approval. Enable private vulnerability reporting
and the required CI checks on `main`. Restrict creation and changes to
version tags to release maintainers.

Create the GitHub environment `hex-publish`. Restrict it to version tags
and enable review where supported by the GitHub plan. Make the existing
Hex publish key available as `HEX_API_KEY` to that environment or as an
approved repository secret. Check that the key can create the first public
package under the intended Hex owner. Keep provider credentials out of CI.

## Publish a version

1. Update `@version` in `mix.exs` and add the matching changelog entry in a
   pull request. Check that the docs and examples still use the correct
   version. The first version is `0.5.0`.
2. Merge the PR and wait for the CI run on the exact commit on `main`.
   Create and push the matching annotated version tag when authorized.
3. Open the Release workflow, select the tag, and run it with publishing
   turned off. Inspect the package manifest and checksum in the workflow's
   artifact. Check the package, docs, and release notes.
4. Run the same workflow for the same tag with publishing turned on.
   Approve the environment if it requests review. The workflow verifies
   the commit before publishing and checks the published package before
   it creates the GitHub release.
5. Open the version on Hex, its HexDocs, and its GitHub release. Check
   the install instruction and the links in the generated start page.

For the first tag, the equivalent GitHub CLI commands after approval are:

```sh
gh workflow run release.yml --ref v0.5.0
gh workflow run release.yml --ref v0.5.0 -f publish=true
```

If Hex succeeds and the GitHub release job fails, rerun the failed job in
the original workflow. If Hex published the version but the publish job
was interrupted, verify the published package and create the GitHub
release from the same tag. For a defective package, have the Hex owner
retire the affected version and ship a fix under a new patch version.

Hex Workload Identity can replace the API key after the package exists
and the Jido projects are ready to make that change.

[Hex publishing](https://hex.pm/docs/publish) ·
[Hex Workload Identity](https://hex.pm/docs/workload-identity)
