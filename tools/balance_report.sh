#!/bin/sh
# Headless pacing run (spec M8): writes the markdown balance report. Usage: tools/balance_report.sh [output.md]
dir=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$dir/docs/BALANCE_REPORT.md"}
cd "$dir" && luau tools/balance_report.luau > "$out" && echo "wrote $out"
