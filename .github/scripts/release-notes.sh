#!/usr/bin/env bash
set -euo pipefail

version="${1:?Pass the release version.}"
changelog="${2:-CHANGELOG.md}"

awk -v version="$version" '
  /^## / {
    if (found) exit
    found = ($0 == "## " version || index($0, "## [" version "](") == 1)
    next
  }
  found { print }
  END { if (!found) exit 1 }
' "$changelog"
