#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: bash .github/scripts/smoke-consumer.sh SOURCE_DIR_OR_HEX_VERSION core|workbench" >&2
  exit 2
fi

source_or_version="$1"
mode="$2"

case "$mode" in
  core | workbench) ;;
  *) echo "Unknown consumer mode: $mode" >&2; exit 2 ;;
esac

if [[ -d "$source_or_version" ]]; then
  export TUNE_SMOKE_SOURCE="$(cd "$source_or_version" && pwd -P)"
  unset TUNE_SMOKE_VERSION
elif [[ "$source_or_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  export TUNE_SMOKE_VERSION="$source_or_version"
  unset TUNE_SMOKE_SOURCE
else
  echo "Expected a Tune source directory or stable Hex version." >&2
  exit 2
fi

export TUNE_SMOKE_MODE="$mode"
export MIX_ENV=prod
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
consumer="$(mktemp -d)"
trap 'rm -rf "$consumer"' EXIT

cat > "$consumer/mix.exs" <<'ELIXIR'
defmodule TuneSmoke.MixProject do
  use Mix.Project

  def project, do: [app: :tune_smoke, version: "0.0.0", deps: deps()]

  def application, do: [extra_applications: [:inets]]

  defp deps do
    tune =
      case System.fetch_env("TUNE_SMOKE_SOURCE") do
        {:ok, path} -> {:tune, path: path}
        :error -> {:tune, "== " <> System.fetch_env!("TUNE_SMOKE_VERSION")}
      end

    case System.fetch_env!("TUNE_SMOKE_MODE") do
      "core" -> [tune]
      "workbench" -> [tune, {:phoenix_playground, "~> 0.1.9"}]
    end
  end
end
ELIXIR

cd "$consumer"
mix deps.get
mix run "$script_dir/smoke-consumer.exs"
