#!/bin/sh
# Command-center price counterfactual (GR5-63). Usage: tools/price_compare.sh [output.md]
dir=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$dir/docs/PRICE_COMPARE.md"}
cd "$dir" && luau tools/price_compare.luau > "$out" && echo "wrote $out"
