#!/bin/sh
# GR5-89: runs the real runtime with config/debug.luau `qaTour = true` (set it for the run, put it back after) and takes a
# screenshot every second for the length of the tour. The step name is drawn in the feed header ("[QA 05 team]"), so the
# frames are matched to steps by reading the image. macOS only; the window id comes from CoreGraphics.
# Usage: tools/qa_capture.sh path/to/aylo-runtime out_dir [seconds]
runtime=${1:?usage: $0 path/to/aylo-runtime out_dir [seconds]}; out=${2:?out_dir}; secs=${3:-130}
dir=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
tmp=$(mktemp -d)
cat > "$tmp/winid.swift" <<'SW'
import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String:Any]]
for w in l { if (w[kCGWindowOwnerName as String] as? String) == "aylo-runtime", (w[kCGWindowBounds as String] as! [String:Any])["Width"] as! Int > 800 { print(w[kCGWindowNumber as String]!); break } }
SW
swiftc -o "$tmp/winid" "$tmp/winid.swift" || exit 1
"$runtime" "$dir" > "$out/runtime.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; rm -rf "$tmp"' EXIT
i=0
while [ $i -lt "$secs" ]; do
  sleep 1; i=$((i + 1))
  id=$("$tmp/winid"); [ -n "$id" ] && screencapture -x -o -l "$id" "$out/$(printf '%03d' $i).png"
done
