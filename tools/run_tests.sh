#!/bin/sh
# Headless test runner (spec M0): runs every tests/*.luau on the Luau CLI, fails on the first error.
# The .luaurc `@scripts` alias is found from the test file, so this works from any directory.
dir=$(cd "$(dirname "$0")/.." && pwd)
status=0
echo "== check_system_order"
python3 "$dir/tools/check_system_order.py" || status=1
echo "== check_palette"
"$dir/tools/check_palette.sh" || status=1
echo "== check_audio"
"$dir/tools/check_audio.sh" || status=1
echo "== check_icons"
"$dir/tools/check_icons.sh" || status=1
echo "== check_ui_assets"
"$dir/tools/check_ui_assets.sh" || status=1
echo "== check_station_assets"
"$dir/tools/check_station_assets.sh" || status=1
for t in "$dir"/tests/*.luau; do
  echo "== $(basename "$t")"
  luau "$t" || status=1
done
exit $status
