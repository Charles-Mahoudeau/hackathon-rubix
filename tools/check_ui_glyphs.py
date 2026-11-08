#!/usr/bin/env python3
"""String literals in scripts/ must only use characters the UI font has (U+0020-007E, U+00A0-00FF, charset.txt); anything else
draws as "?". Comments are ignored. tests/test_ui_lint.luau checks the texts the screens really draw."""
import glob, os, re, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ok = lambda c: c in "\t\n" or 0x20 <= ord(c) <= 0x7E or 0xA0 <= ord(c) <= 0xFF
lit = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')
bad = 0
for f in sorted(glob.glob(os.path.join(root, "scripts", "**", "*.luau"), recursive=True)):
    for n, line in enumerate(open(f, encoding="utf8"), 1):
        code = line.split("--")[0] if '"' not in line.split("--")[0][-1:] else line
        for m in lit.finditer(code):
            for c in m.group(0):
                if not ok(c):
                    print("%s:%d: U+%04X not in the UI font: %s" % (os.path.relpath(f, root), n, ord(c), m.group(0)[:60]))
                    bad = 1
print("ui glyphs ok" if not bad else "ui glyph problems")
sys.exit(bad)
