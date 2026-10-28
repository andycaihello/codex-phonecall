#!/usr/bin/env python3
"""Offline native parser checks: every action uses --validate-args.

No device APIs, AppKit, permissions, IPC connection, application launch or dial.
The additional command-validation stream is a parser-only native mode.
"""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
ADDRESS, NAME = 'AA:BB:CC:DD:EE:FF', 'Offline Test Phone'
TARGET = ['--phone-address', ADDRESS, '--phone-name', NAME]
ENTRIES = [
    ('control', ROOT / 'bluetooth-call-control', ['--run', '--allow-number', '12345']),
    ('acl', ROOT / 'prepare-phone-acl', ['--prepare-paired-phone']),
    ('pcm', ROOT / 'audio/PhoneBridgePCM.app/Contents/MacOS/phonebridge-pcm',
     ['--bridge', '--socket', '/private/tmp/offline-identity/socket', '--token-file', '/private/tmp/offline-identity/token']),
]
checks = []


def check(entry, identity, expected, label, extra=None):
    kind, binary, base = entry
    args = [*base, *identity, *(extra or []), '--validate-args']
    proc = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=3)
    value = json.loads(proc.stdout)
    assert proc.returncode == (0 if expected else 2), (kind, label, proc.stdout, proc.stderr)
    assert value['deviceQueries'] is False, (kind, label)
    if kind == 'pcm':
        assert value['ioStarted'] is False
        if expected:
            target = identity[identity.index('--phone-address') + 1].replace(':', '-')
            assert value['input_uid'] == target + ':input'
            assert value['output_uid'] == target + ':output'
            assert value['device_name'] == identity[identity.index('--phone-name') + 1]
            assert value['socketConnected'] is False and value['permissionRequested'] is False
    if kind == 'acl':
        assert value['freshACLRequested'] is False
    if kind == 'control':
        assert value['dialed'] is False
    checks.append(kind + ': ' + label)


for entry in ENTRIES:
    check(entry, TARGET, True, 'explicit selected identity')
    check(entry, ['--phone-address', '01:23:45:67:89:AB', '--phone-name', '迁移设备'], True, 'different address and Unicode name')
    check(entry, ['--phone-address', ADDRESS, '--phone-name', 'é' * 64], True, '128 UTF-8 bytes')
    for target, label in [([], 'missing identity'), (['--phone-name', NAME], 'missing address'),
                          (['--phone-address', ADDRESS], 'missing name')]:
        check(entry, target, False, label)
    for address in ['', 'aa:bb:cc:dd:ee:ff', 'AA-BB-CC-DD-EE-FF', 'AA:BB:CC:DD:EE',
                    'AA:BB:CC:DD:EE:FG', ' AA:BB:CC:DD:EE:FF', 'AA:BB:CC:DD:EE:FF\n']:
        check(entry, ['--phone-address', address, '--phone-name', NAME], False, 'invalid address ' + repr(address))
    for name in ['', '  ', '\t', 'name\nother', '\x7f', 'é' * 65, '--validate-args']:
        check(entry, ['--phone-address', ADDRESS, '--phone-name', name], False, 'invalid name ' + repr(name))
    check(entry, TARGET, False, 'duplicate address', ['--phone-address', ADDRESS])
    check(entry, TARGET, False, 'duplicate name', ['--phone-name', NAME])
    check(entry, TARGET, False, 'reject device fallback option', ['--use-default-device'])

control = ENTRIES[0]
check(('control', control[1], ['--run']), TARGET, False, 'missing authorized number')
check(control, TARGET, False, 'duplicate authorized number', ['--allow-number', '12345'])
for number in ['', '12', '123;ATD', '１２３', '+1234567890123456']:
    check(('control', control[1], ['--run', '--allow-number', number]), TARGET, False, 'bad authorized number ' + repr(number))

commands = [{'id': 'owned', 'op': 'dial', 'number': '+12345'},
            {'id': 'other', 'op': 'dial', 'number': '12345'},
            {'id': 'old-default', 'op': 'dial', 'number': '13800000000'},
            {'id': 'status', 'op': 'status'}]
proc = subprocess.run([str(control[1]), '--validate-commands', '--allow-number', '+12345'],
                      input=''.join(json.dumps(c) + '\n' for c in commands), capture_output=True, text=True, timeout=3)
rows = [json.loads(line) for line in proc.stdout.splitlines()]
assert proc.returncode == 0 and [r['ok'] for r in rows] == [True, False, False, True]
assert all(r['deviceQueries'] is False and r['dialed'] is False for r in rows)
checks.append('control: parser accepts only explicit authorized number, never prior personal default')

report = {'passed': True, 'checks': len(checks), 'cases': checks, 'deviceQueries': False,
          'appLaunches': 0, 'permissionQueries': 0, 'audioIO': False, 'dialed': False,
          'sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [ROOT / 'phone-identity-arguments.h', *[e[1] for e in ENTRIES]]}}
(ROOT / 'native-portable-identity-validation-20260909.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False))
