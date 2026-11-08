#!/usr/bin/env python3
"""GR5-105: runs the real runtime on the map progression tour (config/debug.luau `mapTour`, flipped for the run and put back after)
and shoots the game window (found by the runtime's pid, so another runtime on the machine is never captured) back to back, naming every frame with its seconds since launch. The step and reveal time are drawn in the
feed header ("[QA 03 t2-mk2-varn t=0.45]"). macOS only. Optional `reduced` flips Vfx.reveal.reducedMotion for the run.
Usage: tools/map_capture.py path/to/aylo-runtime out_dir [seconds] [reduced]"""
import os, re, subprocess, sys, tempfile, time

runtime, out = sys.argv[1], sys.argv[2]
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 75
reduced = len(sys.argv) > 4 and sys.argv[4] == "reduced"
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.makedirs(out, exist_ok=True)

def flip(path, pattern, repl):
    text = open(path).read()
    new = re.sub(pattern, repl, text, count=1)
    assert new != text, path
    open(path, "w").write(new)
    return text

debug, vfx = os.path.join(root, "scripts/config/debug.luau"), os.path.join(root, "scripts/config/vfx.luau")
saved = {debug: flip(debug, r"mapTour = false", "mapTour = true")}
if reduced:
    saved[vfx] = flip(vfx, r"reducedMotion = false", "reducedMotion = true")

tmp = tempfile.mkdtemp()
swift = os.path.join(tmp, "winid.swift")
open(swift, "w").write('''import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String:Any]]
let pid = Int(CommandLine.arguments[1])!
for w in l { if (w[kCGWindowOwnerPID as String] as? Int) == pid, (w[kCGWindowBounds as String] as! [String:Any])["Width"] as! Int > 800 { print(w[kCGWindowNumber as String]!); break } }
''')
subprocess.check_call(["swiftc", "-o", os.path.join(tmp, "winid"), swift])
proc = None
try:
    t0 = time.time()
    proc = subprocess.Popen([runtime, root], stdout=open(os.path.join(out, "runtime.log"), "w"), stderr=subprocess.STDOUT)
    n = 0
    while time.time() - t0 < secs:
        wid = subprocess.run([os.path.join(tmp, "winid"), str(proc.pid)], capture_output=True, text=True).stdout.strip()
        if not wid:
            time.sleep(0.2)
            continue
        at = time.time() - t0
        shot = os.path.join(out, "%03d_%07.2f.jpg" % (n, at))
        subprocess.run(["screencapture", "-x", "-o", "-t", "jpg", "-l", wid, shot])
        subprocess.run(["sips", "-Z", "1280", shot], capture_output=True)  # the window is retina: keep 1280 px wide, disks fill up
        n += 1
    print("frames:", n, "runtime exit:", proc.poll())
finally:
    if proc: proc.kill()
    for path, text in saved.items(): open(path, "w").write(text)
