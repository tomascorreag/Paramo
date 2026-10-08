#!/usr/bin/env python3
"""List shipped project code that names an API the web template compiles out.

The template is built with deprecated=no (engine/paramo_web.py), which drops
every binding Godot wraps in `#ifndef DISABLE_DEPRECATED`. Desktop and the GUT
suite still have them, so a call like Image.create() works everywhere except the
web build, where the script fails to parse. Run after a Godot upgrade or before
trusting a new script on web:

    python3 engine/find_deprecated_uses.py ../godot-4.6.1-src .

Scans scripts/, scenes/, resources/ (not scripts/tools/, which does not ship).
Matching is by name, so a hit is a lead, not a verdict: ALLOW lists the ones
checked and found to be something else. Exit 1 if anything unexplained is left.
"""
import os
import re
import sys

# name -> why it is not a use of the deprecated binding
ALLOW = {
    "has_feature": "OS.has_feature is current; only RenderingServer.has_feature is deprecated",
    "resource_changed": "ResourceLedger's own signal, not the 3D nodes' deprecated one",
}
SHIPPED_DIRS = ("scripts", "scenes", "resources")
NOT_SHIPPED = (os.path.join("scripts", "tools"),)


def deprecated_names(godot_src):
    names = {}
    for d, _, files in os.walk(godot_src):
        if any(part in d for part in ("/thirdparty", "/editor", "/tests", "/.git")):
            continue
        for f in files:
            if not f.endswith((".cpp", ".h")):
                continue
            path = os.path.join(d, f)
            stack = []
            for line in open(path, encoding="utf-8", errors="ignore"):
                s = line.strip()
                if s.startswith("#if"):
                    stack.append(s.startswith("#ifndef DISABLE_DEPRECATED"))
                elif s.startswith("#else") and stack:
                    stack[-1] = False
                elif s.startswith("#endif") and stack:
                    stack.pop()
                elif any(stack):
                    for m in re.finditer(r'D_METHOD\("(\w+)"', s):
                        names.setdefault(m.group(1), set()).add(os.path.relpath(path, godot_src))
                    for m in re.finditer(r'ADD_PROPERTY\(PropertyInfo\([^,]+,\s*"([\w/]+)"', s):
                        names.setdefault(m.group(1), set()).add(os.path.relpath(path, godot_src))
                    for m in re.finditer(r"BIND_(?:ENUM_)?CONSTANT\((\w+)\)", s):
                        names.setdefault(m.group(1), set()).add(os.path.relpath(path, godot_src))
    return names


def shipped_files(project):
    for top in SHIPPED_DIRS:
        for d, _, files in os.walk(os.path.join(project, top)):
            rel = os.path.relpath(d, project)
            if rel.startswith(NOT_SHIPPED):
                continue
            for f in files:
                if f.endswith((".gd", ".tscn", ".tres")):
                    yield os.path.join(d, f)


def main():
    godot_src, project = sys.argv[1], sys.argv[2]
    names = deprecated_names(godot_src)
    patterns = {}
    for n in names:
        if "/" in n:
            patterns[n] = re.compile(r"^" + re.escape(n) + r" = ")
        elif n.isupper():
            patterns[n] = re.compile(r"\b" + n + r"\b")
        else:
            patterns[n] = re.compile(r"(?:^|[^\w])" + n + r"(?:\(| = )")
    unexplained = 0
    for path in shipped_files(project):
        for lineno, line in enumerate(open(path, encoding="utf-8", errors="ignore"), 1):
            code = line.split("#", 1)[0] if path.endswith(".gd") else line
            for n, pat in patterns.items():
                if pat.search(code):
                    tag = "allowed" if n in ALLOW else "CHECK"
                    unexplained += n not in ALLOW
                    print(f"{tag:8} {os.path.relpath(path, project)}:{lineno}  {n}  ({', '.join(sorted(names[n]))})")
    print(f"{len(names)} deprecated bindings; {unexplained} unexplained use(s)")
    sys.exit(1 if unexplained else 0)


if __name__ == "__main__":
    main()
