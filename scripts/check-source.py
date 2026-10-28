#!/usr/bin/env python3
"""Check tracked Python/JSON syntax, local Markdown links and private file names.

No device, runtime-file, network, audio or API access. This is a source hygiene
check, not a substitute for GitHub secret scanning or review of Git history.
"""
import ast
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FILES = [ROOT / p for p in subprocess.check_output(
    ["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0") if p]
PRIVATE_NAMES = {"runtime.json", "local.properties", ".mcp.json", ".env"}
PRIVATE_SUFFIXES = {".p12", ".p7b", ".pfx", ".jks", ".keystore", ".pem", ".key", ".cer", ".hap"}
errors = []
for path in FILES:
    relative = str(path.relative_to(ROOT))
    if path.name in PRIVATE_NAMES or path.suffix.lower() in PRIVATE_SUFFIXES:
        errors.append(relative + ": private/generated configuration must not be tracked")
    if path.suffix == ".py":
        try:
            ast.parse(path.read_text(), filename=relative)
        except (SyntaxError, UnicodeError):
            errors.append(relative + ": invalid Python syntax")
    if path.suffix == ".json":
        try:
            json.loads(path.read_text())
        except (ValueError, UnicodeError):
            errors.append(relative + ": invalid JSON")
    if path.suffix == ".md":
        for target in re.findall(r'(?:\]\(|src=")([^)"]+)', path.read_text()):
            if re.match(r"(?:[A-Za-z][A-Za-z0-9+.-]*:|#)", target):
                continue
            target = target.split("#")[0]
            if target and not (path.parent / target).exists():
                errors.append(relative + ": broken local link: " + target)

for message in errors:
    print(message)
if errors:
    raise SystemExit(1)
print(f"PASS: {len(FILES)} tracked files checked; no device or API operations.")
