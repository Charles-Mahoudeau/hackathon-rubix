#!/bin/sh
# Engine-level headless test (spec M0): boots the game in aylo-runtime, runs scripts/server/selftest.luau, exits 0 on pass.
# Usage: tools/run_engine_test.sh path/to/aylo-runtime   (or set AYLO_RUNTIME)
# --ticks is only a safety net: it also exits 0, so a pass needs the "selftest: PASS" line, not just the exit code.
runtime=${1:-$AYLO_RUNTIME}
[ -x "$runtime" ] || { echo "usage: $0 path/to/aylo-runtime (or set AYLO_RUNTIME)" >&2; exit 2; }
dir=$(cd "$(dirname "$0")/.." && pwd)
log=$(mktemp)
"$runtime" "$dir" --server --selftest --ticks 600 >"$log" 2>&1
code=$?
cat "$log"
if [ "$code" -ne 0 ]; then echo "engine self-test failed (exit $code)" >&2; rm -f "$log"; exit "$code"; fi
if ! grep -q '^selftest: PASS' "$log"; then echo "engine self-test never reported PASS" >&2; rm -f "$log"; exit 1; fi
rm -f "$log"
