#!/usr/bin/env python3
"""Native receive-only argument/command checks. Parser-only; no radio queries."""
import json
from pathlib import Path
import subprocess

binary = Path(__file__).resolve().parent / "bluetooth-call-control"
identity = ["--phone-address", "AA:BB:CC:DD:EE:FF", "--phone-name", "Offline Phone"]
checks = 0
for scope, expected in [(["--incoming-only"], True),
                        (["--incoming-only", "--allow-number", "5551234"], False),
                        (["--allow-number", "5551234"], True), ([], False)]:
    p = subprocess.run([str(binary), "--run", *scope, *identity, "--validate-args"],
                       capture_output=True, text=True, check=False, timeout=3)
    value = json.loads(p.stdout)
    assert value["ok"] is expected and value["deviceQueries"] is False and value["dialed"] is False
    assert p.returncode == (0 if expected else 2)
    checks += 1

commands = [({"id": "answer-1", "op": "answer", "incoming_id": "1"}, True),
            ({"id": "no-token", "op": "answer"}, False),
            ({"id": "fake-number", "op": "dial", "number": "5551234"}, False),
            ({"id": "fake-ui", "op": "helper_dial_ui", "number": "5551234"}, False),
            ({"id": "wrong-token-type", "op": "answer", "incoming_id": 1}, False),
            ({"id": "zero-token", "op": "answer", "incoming_id": "0"}, False),
            ({"id": "injected", "op": "answer", "incoming_id": "1\rATD5551234;"}, False),
            ({"id": "extra", "op": "answer", "incoming_id": "1", "number": "5551234"}, False)]
for scope in (["--incoming-only"], ["--allow-number", "5551234"]):
    p = subprocess.run([str(binary), "--validate-commands", *scope],
                       input="\n".join(json.dumps(c) for c, _ in commands) + "\n",
                       capture_output=True, text=True, check=True, timeout=3)
    rows = [json.loads(line) for line in p.stdout.splitlines()]
    assert len(rows) == len(commands)
    for (command, allowed), result in zip(commands, rows):
        if "--incoming-only" not in scope:
            allowed = command["op"] in ("dial", "helper_dial_ui") and len(command) == 3
        assert result["ok"] is allowed, (command["id"], scope)
        assert result["deviceQueries"] is False and result["dialed"] is False
        checks += 1
print(f"PASS: {checks} receive-only native parser checks; no phone operations")
