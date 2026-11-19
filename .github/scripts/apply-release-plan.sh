#!/usr/bin/env bash
set -euo pipefail

files="${1:?Pass the generated release directory.}"
cp "$files/mix.exs" mix.exs
cp "$files/CHANGELOG.md" CHANGELOG.md
cp "$files/README.md" README.md
cp "$files/guides__compatibility.md" guides/compatibility.md
