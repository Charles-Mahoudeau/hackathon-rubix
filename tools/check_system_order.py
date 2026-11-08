#!/usr/bin/env python3
"""System-order gate: the engine refuses to start when two systems of the same phase touch one component, one of them
writing it, with no before/after path between them ("Systems of phase Update touch the same data with no order ...").
The headless Luau tests never register systems, so this reads the engine.ecs.system declarations in scripts/ instead."""
import itertools, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent / "scripts"
systems = {}

def strings(block):
    return re.findall(r'"([^"]+)"', block or "")

def field(body, name):
    m = re.search(r'\b%s\s*=\s*\{([^{}]*)\}' % name, body)
    return strings(m.group(1)) if m else []

def query_list(body, kind):
    m = re.search(r'\bquery\s*=\s*\{(.*?)\}\s*,?\s*(?:\n|\b\w+\s*=)', body, re.S)
    q = re.search(r'\bquery\s*=\s*\{', body)
    if not q:
        return []
    depth, i = 1, q.end()
    while depth and i < len(body):
        depth += {"{": 1, "}": -1}.get(body[i], 0)
        i += 1
    return field(body[q.end():i - 1], kind)

for path in sorted(root.rglob("*.luau")):
    text = path.read_text()
    for m in re.finditer(r'engine\.ecs\.system\(\s*"([^"]+)"\s*,\s*\{', text):
        depth, i = 1, m.end()
        while depth and i < len(text):
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        body = text[m.end():i - 1]
        phase = re.search(r'\bphase\s*=\s*"(\w+)"', body)
        side = re.search(r'\bside\s*=\s*"(\w+)"', body)
        systems[m.group(1)] = {
            "file": path.relative_to(root.parent), "phase": phase.group(1) if phase else "Update",
            "side": side.group(1) if side else "both",
            "read": set(query_list(body, "read")), "write": set(query_list(body, "write")),
            "after": set(field(body, "after")), "before": set(field(body, "before")),
        }

after = {n: set(s["after"]) for n, s in systems.items()}
for n, s in systems.items():
    for b in s["before"]:
        if b in after:
            after[b].add(n)

def ordered(a, b):
    def reaches(x, y, seen=()):
        return y in after.get(x, ()) or any(reaches(z, y, seen + (x,)) for z in after.get(x, ()) if z not in seen)
    return reaches(a, b) or reaches(b, a)

bad = []
for a, b in itertools.combinations(sorted(systems), 2):
    sa, sb = systems[a], systems[b]
    if sa["phase"] != sb["phase"] or "both" not in (sa["side"], sb["side"]) and sa["side"] != sb["side"]:
        continue
    shared = (sa["write"] & (sb["read"] | sb["write"])) | (sb["write"] & sa["read"])
    if shared and not ordered(a, b):
        bad.append(f"  '{a}' ({sa['file']}) and '{b}' ({sb['file']}) both use {', '.join(sorted(shared))}, one writing it: add after/before")
for n, s in systems.items():
    for dep in s["after"] | s["before"]:
        if dep not in systems:
            bad.append(f"  '{n}' orders itself against unknown system '{dep}'")
if bad:
    print("system order: unordered systems would abort the engine at startup:")
    print("\n".join(bad))
    sys.exit(1)
print(f"system order: {len(systems)} systems, every pair that shares written data is ordered")
