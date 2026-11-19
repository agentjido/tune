#!/usr/bin/env bash
set -euo pipefail

docs_dir="${1:-doc}"
version="$(sed -nE 's/^  @version "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' mix.exs)"
test -n "$version"

for page in index readme getting_started programs changelog security; do
  test -s "$docs_dir/$page.html"
done

for page in getting_started programs changelog; do
  grep -Fq "href=\"$page.html\"" "$docs_dir/readme.html"
done

source_url="https://github.com/agentjido/tune"
grep -Fq "href=\"$source_url/blob/v$version/README.md" "$docs_dir/readme.html"

for example in examples examples/01_dspy/01_01_extract_ticket examples/03_evolution/03_01_batch_grid; do
  test -d "$example"
  grep -Fq "href=\"$source_url/tree/v$version/$example\"" "$docs_dir/readme.html"
done

echo "Generated release docs and example links verified."
