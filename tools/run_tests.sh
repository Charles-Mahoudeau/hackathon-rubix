#!/bin/sh
# Headless test runner (spec M0): runs every tests/*.luau on the Luau CLI, fails on the first error.
# The .luaurc `@scripts` alias is found from the test file, so this works from any directory.
dir=$(cd "$(dirname "$0")/.." && pwd)
status=0
for t in "$dir"/tests/*.luau; do
  echo "== $(basename "$t")"
  luau "$t" || status=1
done
exit $status
