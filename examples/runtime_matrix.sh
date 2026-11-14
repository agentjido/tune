#!/bin/sh
# Compiles with warnings as errors and runs the offline suite on each installed
# Elixir/OTP pair, in throwaway copies of the project. Requires mise.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
for pair in "1.18.4-otp-27:27.3.4.12" "1.19.5-otp-28:28.5" "1.20.4-otp-29:29.1.2"; do
  ex=${pair%%:*}
  erl=${pair##*:}
  dir=$(mktemp -d)
  rsync -a --exclude _build --exclude doc "$root/" "$dir/"
  echo "== elixir $ex / erlang $erl"
  (cd "$dir" && mise exec "elixir@$ex" "erlang@$erl" -- sh -c 'mix compile --warnings-as-errors > /dev/null 2>&1 && echo "compile ok" || echo "compile FAILED"; mix test 2>&1 | tail -1')
  rm -rf "$dir"
done
