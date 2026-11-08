#!/bin/sh
# Regenerates docs/BRANCH_PROFIT_REPORT.md (GR5-64): every branch against a mining-only control on seeds 1-5. About one minute.
dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$dir" && luau tools/branch_report.luau > docs/BRANCH_PROFIT_REPORT.md
