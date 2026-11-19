#!/usr/bin/env bash
set -euo pipefail

output_dir="${1:?Pass an output directory for the package and manifest.}"
mix hex.audit
bash .github/scripts/check-package.sh "$output_dir"
mix hex.publish --dry-run --yes
bash .github/scripts/check-docs.sh
