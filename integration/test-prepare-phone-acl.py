#!/usr/bin/env python3
"""Parse-only tests. Every potentially valid action includes --validate-args."""
import hashlib
import json
import pathlib
import subprocess

folder = pathlib.Path(__file__).resolve().parent
exe = folder / 'prepare-phone-acl'
identity = ['--phone-address', 'AA:BB:CC:DD:EE:FF', '--phone-name', 'Offline Test Phone']
cases = [
    (['--prepare-paired-phone', *identity, '--validate-args'], True),
    (['--validate-args', '--prepare-paired-phone', *identity], True),
    (['--prepare-paired-phone', '--validate-args'], False),
    (['--validate-args'], False),
    (['--prepare-paired-phone', '--prepare-paired-phone', '--validate-args'], False),
    (['--prepare-paired-phone', '--validate-args', '--validate-args'], False),
    (['--connect-paired-phone', '--validate-args'], False),
    (['--prepare-paired-phone', '--address', 'arbitrary', '--validate-args'], False),
    (['--prepare-paired-phone', '--hold-for-helper-test', '--validate-args'], False),
    (['--prepare-paired-phone', '--close', '--validate-args'], False),
    (['--prepare-paired-phone', '--dial', 'unapproved', '--validate-args'], False),
    (['--prepare-paired-phone', '--sdp', '--validate-args'], False),
]
for args, success in cases:
    run = subprocess.run([str(exe), *args], capture_output=True, text=True, timeout=3)
    value = json.loads(run.stdout)
    assert (run.returncode == 0) == success, (args, run.stdout, run.stderr)
    assert value['deviceQueries'] is False and value['freshACLRequested'] is False
    assert value['stage'] == ('arguments-valid' if success else 'argument-error')
out = {'passed': True, 'checks': len(cases), 'scope': 'Offline argument validation only; no Bluetooth query/connection or App/device action',
       'sha256': {name: hashlib.sha256((folder / name).read_bytes()).hexdigest() for name in
                  ['prepare-phone-acl.m', 'prepare-phone-acl', 'build-prepare-phone-acl.sh']}}
(folder / 'prepare-phone-acl-validation.json').write_text(json.dumps(out, indent=2) + '\n')
print(json.dumps(out))
