#!/bin/sh
# Rewrites the measured section of docs/COMPUTE_AUDIT.md (GR5-66); the verdict above "# Measured output" is hand-written.
dir=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$dir/docs/COMPUTE_AUDIT.md"}
tmp=$(mktemp)
sed '/^# Measured output$/q' "$out" > "$tmp" && (cd "$dir" && luau tools/compute_audit_report.luau) >> "$tmp" && mv "$tmp" "$out" && echo "wrote $out"
