#!/bin/sh
# Palette gate (GR5-3): config/theme.luau is the only colour source. Fails if another script spells a hex colour
# (0xRRGGBB or "#rrggbb"), and lists the theme palette so the count (<= 8) is visible in the log.
dir=$(cd "$(dirname "$0")/.." && pwd)
theme="$dir/scripts/config/theme.luau"
hits=$(grep -rnE '0x[0-9A-Fa-f]{6}\b|"#[0-9A-Fa-f]{6}"|#[0-9A-Fa-f]{6}\b' "$dir/scripts" --include='*.luau' | grep -v "^$theme:" | grep -v '^[^:]*:[0-9]*:[[:space:]]*--')
if [ -n "$hits" ]; then
  echo "palette: colours outside config/theme.luau:"; echo "$hits"; exit 1
fi
count=$(awk '/palette = \{/{f=1;next} f&&/\}/{exit} f&&/0x[0-9A-Fa-f]{6}/{n++} END{print n+0}' "$theme")
echo "palette: $count colours, all in config/theme.luau"
[ "$count" -le 8 ] || { echo "palette: more than 8 colours"; exit 1; }
