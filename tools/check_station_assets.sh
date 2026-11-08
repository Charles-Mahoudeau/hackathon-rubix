#!/bin/sh
# Every station, turret frame and debris sprite config/stations.luau can draw must exist under assets/ (GR5-52).
dir=$(cd "$(dirname "$0")/.." && pwd)
status=0
count=0
list=$(luau "$dir/tools/list_station_assets.luau") || { echo "list_station_assets failed"; exit 1; }
OLDIFS=$IFS
IFS='
'
for f in $list; do
  count=$((count + 1))
  if [ ! -s "$dir/assets/$f" ]; then echo "missing or empty: assets/$f"; status=1; fi
done
IFS=$OLDIFS
[ $status -eq 0 ] && echo "station assets ok ($count files)"
exit $status
