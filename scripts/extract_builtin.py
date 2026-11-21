#!/usr/bin/env python3
"""Print the built-in config presets of unsyk.lua (the `cfg.builtin = { ... }` block) as JSON.

deploy.sh ships the result as /opt/hvh-ingest/builtin_presets.json so the admin panel can show what the script
carries and publish it as an official (server) preset. Only the simple line format the block uses is understood:
    { name = "unsyk preset", builtin = true, data = {
        ["Section/Item"] = true | false | 12 | -1.5 | "text",
    } },
Anything else inside the block fails loudly, so a format change is caught at deploy time instead of silently
dropping settings.
"""
import json
import re
import sys

START = re.compile(r"^\s*cfg\.builtin\s*=\s*\{\s*$")
ENTRY = re.compile(r'^\s*\{\s*name\s*=\s*"([^"\\]+)"\s*,\s*builtin\s*=\s*true\s*,\s*data\s*=\s*\{\s*$')
ITEM = re.compile(r'^\s*\["([^"\\]+)"\]\s*=\s*(true|false|-?\d+(?:\.\d+)?|"[^"\\]*")\s*,\s*$')
ENTRY_END = re.compile(r"^\s*\}\s*\}\s*,?\s*$")
BLOCK_END = re.compile(r"^\s*\}\s*$")


def value(tok):
    if tok in ("true", "false"):
        return tok == "true"
    if tok.startswith('"'):
        return tok[1:-1]
    return float(tok) if "." in tok else int(tok)


def extract(lines):
    out, cur, inside = [], None, False
    for no, line in enumerate(lines, 1):
        if not inside:
            inside = bool(START.match(line))
            continue
        if cur is None:
            m = ENTRY.match(line)
            if m:
                cur = {"name": m.group(1), "data": {}}
                continue
            if BLOCK_END.match(line):
                return out
            if line.strip() and not line.strip().startswith("--"):
                raise SystemExit(f"extract_builtin: line {no}: unexpected {line.strip()!r}")
            continue
        m = ITEM.match(line)
        if m:
            cur["data"][m.group(1)] = value(m.group(2))
        elif ENTRY_END.match(line):
            out.append(cur)
            cur = None
        elif line.strip() and not line.strip().startswith("--"):
            raise SystemExit(f"extract_builtin: line {no}: unexpected {line.strip()!r}")
    raise SystemExit("extract_builtin: no complete cfg.builtin block found")


if __name__ == "__main__":
    presets = extract(open(sys.argv[1], encoding="utf-8").read().splitlines())
    if not presets or not all(p["data"] for p in presets):
        raise SystemExit("extract_builtin: empty preset")
    json.dump({"presets": presets}, sys.stdout, ensure_ascii=False, indent=1)
    print()
