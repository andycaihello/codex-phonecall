#!/usr/bin/env python3
"""Pure validation only: every invocation includes --validate-launch-args."""
import hashlib
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
launcher = root / 'pcm-permission-launcher'
app = root / 'PhoneBridgePCM.app'
results = []
with tempfile.TemporaryDirectory(prefix='phonebridge-permission-args-') as raw:
    folder = pathlib.Path(raw).resolve()
    folder.chmod(0o700)
    report, status = folder / 'native.json', folder / 'status.json'
    base = ['--application', str(app), '--report', str(report), '--status', str(status)]
    flags = ['--microphone-permission-status', '--request-microphone-permission']
    cases = []
    for flag in flags:
        cases.append((base + ['--limit', '55', '--validate-launch-args', '--', flag], True))
    for limit in ['0', '55.1', '56', 'NaN', 'Infinity', '-1']:
        cases.append((base + ['--limit', limit, '--validate-launch-args', '--', flags[0]], False))
    for native in [[], ['--bridge'], [flags[0], flags[1]], [flags[0], '--report', str(report)],
                   [flags[0], '--max-seconds', '1'], [flags[0], '--validate-args'], ['--speech-permission-status']]:
        cases.append((base + ['--limit', '55', '--validate-launch-args', '--', *native], False))
    cases.append((base + ['--limit', '55', '--validate-launch-args', '--validate-launch-args', '--', flags[0]], False))
    cases.append((base + ['--limit', '55', '--report', str(report), '--validate-launch-args', '--', flags[0]], False))
    cases.append((['--application', str(root.parents[1] / 'diagnostics/SilentCoreAudioProbe.app'), '--report', str(report), '--status', str(status), '--limit', '55', '--validate-launch-args', '--', flags[0]], False))
    cases.append((['--application', str(app), '--report', str(report), '--status', str(report), '--limit', '55', '--validate-launch-args', '--', flags[0]], False))
    for args, expected in cases:
        run = subprocess.run([str(launcher), *args], capture_output=True, text=True, timeout=3)
        value = json.loads(run.stdout)
        assert (run.returncode == 0) == expected, (args, run.stdout, run.stderr)
        assert not report.exists() and not status.exists(), 'Validation created a report or launched an App'
        if expected:
            assert value['launchRequested'] is False and value['deviceQueries'] is False and value['nativeArgumentsValidated'] is True
        results.append({'expectedSuccess': expected, 'passed': True})
    # Directory permissions and existing/dangling paths are rejected before launch.
    valid = base + ['--limit', '55', '--validate-launch-args', '--', flags[0]]
    folder.chmod(0o755)
    run = subprocess.run([str(launcher), *valid], capture_output=True, text=True, timeout=3)
    assert run.returncode == 2; results.append({'case': 'nonprivate-parent', 'passed': True})
    folder.chmod(0o700)
    report.symlink_to(folder / 'absent-target')
    run = subprocess.run([str(launcher), *valid], capture_output=True, text=True, timeout=3)
    assert run.returncode == 2; results.append({'case': 'dangling-report-symlink', 'passed': True})
predicate = subprocess.run([str(root / 'pcm-permission-report-test')], capture_output=True, text=True, check=True, timeout=3)
predicate_result = json.loads(predicate.stdout)
out = {'passed': True, 'argumentChecks': len(results), 'reportPredicateChecks': predicate_result['checks'],
       'launchRequested': False, 'permissionQueries': False, 'deviceQueries': False,
       'sha256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in
                  ['pcm-permission-launcher.m', 'pcm-permission-launcher', 'build-pcm-permission-launcher.sh', 'PhoneBridgePCM.app/Contents/MacOS/phonebridge-pcm']}}
(root / 'permission-launcher-validation.json').write_text(json.dumps(out, indent=2) + '\n')
print(json.dumps(out))
