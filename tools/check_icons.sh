#!/bin/sh
# Every icon scripts/ui/icon_set.luau names must exist under assets/ (a missing file fails only at runtime, on the client).
dir=$(cd "$(dirname "$0")/.." && pwd)
status=0
for f in $(grep -o '"icons/[A-Za-z0-9_./-]*"' "$dir/scripts/ui/icon_set.luau" | tr -d '"' | sort -u); do
  if [ ! -s "$dir/assets/$f" ]; then echo "missing or empty: assets/$f"; status=1; fi
done
[ $status -eq 0 ] && echo "icon files ok"
exit $status
