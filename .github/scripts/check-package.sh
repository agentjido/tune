#!/usr/bin/env bash
set -euo pipefail

output_dir="${1:?Pass an output directory for the package and manifest.}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
archive="$output_dir/tune.tar"

mix hex.build --output "$archive"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xf "$archive" -C "$work"
LC_ALL=C tar -tzf "$work/contents.tar.gz" | LC_ALL=C sort > "$output_dir/manifest.txt"

while IFS= read -r file; do
  case "$file" in
    .formatter.exs | mix.exs | README.md | LICENSE | CHANGELOG.md | CONTRIBUTING.md | SECURITY.md | lib/* | guides/*)
      ;;
    *)
      echo "Unexpected package entry: $file" >&2
      exit 1
      ;;
  esac

  case "/$file/" in
    */../* | */.env/*)
      echo "Forbidden package entry: $file" >&2
      exit 1
      ;;
  esac
done < "$output_dir/manifest.txt"

for required in LICENSE mix.exs README.md lib/tune.ex lib/mix/tasks/tune.ui.ex guides/getting_started.md; do
  grep -Fxq "$required" "$output_dir/manifest.txt"
done

mkdir "$work/source"
tar -xzf "$work/contents.tar.gz" -C "$work/source"
bash .github/scripts/smoke-consumer.sh "$work/source" core
bash .github/scripts/smoke-consumer.sh "$work/source" workbench

(
  cd "$output_dir"
  shasum -a 256 tune.tar > sha256.txt
)
