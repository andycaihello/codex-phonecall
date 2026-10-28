#!/usr/bin/env python3
"""Parse-only paths. Never initializes AppKit, requests TCC, opens IPC or queries HAL."""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent
exe = root / 'PhoneBridgePCM.app/Contents/MacOS/phonebridge-pcm'
base = ['--bridge', '--phone-address', 'AA:BB:CC:DD:EE:FF', '--phone-name', 'Offline Test Phone',
        '--socket', '/private/tmp/test/socket', '--token-file', '/private/tmp/test/token']
cases = [
    (base + ['--validate-args'], True),
    (base + ['--max-seconds', '1', '--validate-args'], True),
    (base + ['--max-seconds', '300', '--validate-args'], True),
    (base + ['--max-seconds', '301', '--validate-args'], False),
    (base + ['--max-seconds', '0', '--validate-args'], False),
    (base + ['--max-seconds', '1.5', '--validate-args'], False),
    (base + ['--max-seconds', '-1', '--validate-args'], False),
    (base + ['--max-seconds', '9999999999999999', '--validate-args'], False),
    (base + ['--report', '/private/tmp/test/token', '--validate-args'], False),
    (base + ['--bridge', '--validate-args'], False),
    (['--bridge', '--socket', '/private/tmp/s', '--validate-args'], False),
    (['--bridge', '--socket', 'relative', '--token-file', '/private/tmp/t', '--validate-args'], False),
    (['--bridge', '--socket', '/private/tmp/../tmp/s', '--token-file', '/private/tmp/t', '--validate-args'], False),
    (['--bridge', '--socket', '/' + 's' * 105, '--token-file', '/private/tmp/t', '--validate-args'], False),
    (['--microphone-permission-status', '--validate-args'], True),
    (['--request-microphone-permission', '--validate-args'], True),
    (['--request-microphone-permission', '--socket', '/private/tmp/s', '--validate-args'], False),
    (['--microphone-permission-status', '--max-seconds', '1', '--validate-args'], False),
    (['--validate-args'], False),
    (base + ['--microphone-permission-status', '--validate-args'], False),
    (base + ['--uid', 'arbitrary', '--validate-args'], False),
    (['--bridge', '--socket', '/private/tmp/test/socket', '--token-file', '/private/tmp/test/token', '--validate-args'], False),
    (['--microphone-permission-status', '--phone-address', 'AA:BB:CC:DD:EE:FF', '--phone-name', 'Offline Test Phone', '--validate-args'], False),
]
for args, expected in cases:
    result = subprocess.run([str(exe), *args], capture_output=True, text=True, timeout=3)
    report = json.loads(result.stdout)
    assert (result.returncode == 0) == expected, (args, result.stdout, result.stderr)
    assert report['ioStarted'] is False and report['deviceQueries'] is False
    assert report['stage'] == ('arguments-valid' if expected else 'argument-error')
print(json.dumps({'passed': True, 'checks': len(cases), 'deviceIO': False, 'appKitInitialized': False, 'permissionQueries': False}))
