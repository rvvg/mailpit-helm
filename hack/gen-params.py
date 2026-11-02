#!/usr/bin/env python3
"""Render the Parameters table of README.md from `# --` comments in values.yaml.

Usage: hack/gen-params.py charts/mailpit/values.yaml README.md [more README files]
Replaces the block between <!-- PARAMS:START --> and <!-- PARAMS:END -->.
"""
import json, re, subprocess, sys

values_path, *readmes = sys.argv[1:]
lines = open(values_path).read().splitlines()
# PyYAML is not always installed; mikefarah/yq is (GitHub runners, Homebrew)
data = json.loads(subprocess.check_output(["yq", "-o=json", ".", values_path]))

rows, stack, pending = [], [], None
for line in lines:
    if not line.strip() or line.lstrip().startswith("##"):
        continue
    m = re.match(r"^(\s*)# -- (.*)$", line)
    if m:
        pending = [m.group(2)]
        continue
    m = re.match(r"^(\s*)#\s?(.*)$", line)
    if m:
        if pending is not None and not m.group(2).startswith(" "):
            pending.append(m.group(2))
        continue
    m = re.match(r"^(\s*)([A-Za-z0-9_]+):", line)
    if not m:
        continue
    indent = len(m.group(1)) // 2
    stack = stack[:indent] + [m.group(2)]
    if pending is not None:
        key = ".".join(stack)
        node = data
        for k in stack:
            node = node[k]
        rows.append((key, json.dumps(node), " ".join(pending)))
        pending = None

def cell(s):
    return s.replace("|", "\\|")

table = ["| Key | Default | Description |", "|-----|---------|-------------|"]
table += [f"| `{k}` | `{cell(v)}` | {cell(d)} |" for k, v, d in rows]
block = "<!-- PARAMS:START -->\n" + "\n".join(table) + "\n<!-- PARAMS:END -->"

for path in readmes:
    text = open(path).read()
    text = re.sub(r"<!-- PARAMS:START -->.*?<!-- PARAMS:END -->", lambda _: block, text, flags=re.S)
    open(path, "w").write(text)
print(f"{len(rows)} parameters", file=sys.stderr)
