#!/usr/bin/env python3
"""Offline validation only: no operation opening Bluetooth channels is ever executed."""
import hashlib
import json
import pathlib
import re
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
BIN = ROOT / 'bluetooth-call-control'
def run(args, payload=None):
    return subprocess.run([str(BIN), *args], input=payload, capture_output=True, text=True, timeout=5)
def records(result):
    return [json.loads(line) for line in result.stdout.splitlines()]
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

engine = subprocess.run([str(ROOT / 'test-hfp-control-machine')], capture_output=True, text=True, check=True, timeout=5)
state_machine = json.loads(engine.stdout)
parser_process = subprocess.run([str(ROOT / 'test-sdp-rfcomm-parser')], capture_output=True, text=True, check=True, timeout=5)
sdp_parser = json.loads(parser_process.stdout)
assert sdp_parser['passed'] and sdp_parser['rawChannel'] == 3 and not sdp_parser['deviceQueries'] and not sdp_parser['servicePublished']
assert state_machine['passed'] and not state_machine['deviceQueries'] and not state_machine['wireTransportUsed']
# Obtain the compile-time allowlist for offline validation without writing it in the report.
number = re.search(r'testNumber = "([0-9]+)"', (ROOT / 'test-hfp-control-machine.cpp').read_text())[1]
identity = ['--phone-address', 'AA:BB:CC:DD:EE:FF', '--phone-name', 'Validation Phone', '--allow-number', number]
args_cases = [
    (['--help'], 0), (['--validate-args'], 2),
    (['--run', *identity, '--max-seconds', '21600', '--validate-args'], 0),
    (['--max-seconds', 'NaN', '--validate-args'], 2), (['--max-seconds', '0', '--validate-args'], 2),
    (['--max-seconds', '21601', '--validate-args'], 2), (['--max-seconds'], 2), (['--run', '--run'], 2),
    (['--run', '--validate-commands'], 2), (['--address', 'xx'], 2),
]
arg_results = []
for args, code in args_cases:
    result = run(args)
    assert result.returncode == code and all(r['deviceQueries'] is False for r in records(result))
    arg_results.append({'args': args, 'exitCode': result.returncode, 'passed': True})
ops = ['helper_connect','helper_status','helper_exchange','helper_audio','helper_stop','open_hsp','hsp_audio','close_hsp','connect','connect_hfp_anchor','status','refresh','hangup','disconnect','stop']
cases = [(dict(id='test', op=op), True) for op in ops]
cases += [(dict(id='dial', op='dial', number=number), True)]
cases += [(dict(id='dial-ui', op='helper_dial_ui', number=number), True)]
cases += [(dict(id='menu', op='dtmf', key=key), True) for key in '0123456789*#']
cases += [(v, False) for v in [
    [], {}, {'id':'','op':'status'}, {'id':'x\n','op':'status'}, {'id':'x'*65,'op':'status'},
    {'id':'cleanup-reserved','op':'status'}, {'id':'x','op':'ATD'}, {'id':'x','op':'status','number':number},
    {'id':'x','op':'dial'}, {'id':'x','op':'dial','number':7002}, {'id':'x','op':'dial','number':'7002'},
    {'id':'x','op':'dial','number':number+'\rAT+CHUP'}, {'id':'x','op':'dial','number':'10010'},
    {'id':'x','op':'status','extra':False},
    {'id':'x','op':'dtmf'}, {'id':'x','op':'dtmf','key':'12'}, {'id':'x','op':'dtmf','key':'A'},
    {'id':'x','op':'dtmf','key':'\rAT+CHUP'}, {'id':'x','op':'dtmf','key':1},
]]
result = run(['--validate-commands', '--allow-number', number], ''.join(json.dumps(v)+'\n' for v,_ in cases))
assert result.returncode == 0
checked = records(result)
assert len(checked) == len(cases)
for row, (_, expected) in zip(checked, cases):
    assert row['ok'] is expected and row['deviceQueries'] is False and row['dialed'] is False
# --run startup/status/stop use only in-memory state; this exercises supervision without any device request.
began = time.monotonic()
result = run(['--run', *identity, '--max-seconds','15'], '{"id":"status","op":"status"}\n{"id":"stop","op":"stop"}\n')
elapsed = time.monotonic() - began
rows = records(result)
assert result.returncode == 0 and elapsed < 4
assert any(r['event']=='cleanup_finished' and r['cleanupVerified'] for r in rows)
assert all(r.get('state',{}).get('channels',{}) == {} for r in rows)
assert not any(r['event'] in ('acl_open_submitted','sdp_complete','at_command','channel_open') for r in rows)
report = {
    'schema': 1, 'passed': True, 'actualDeviceQueriesRun': False, 'actualBluetoothConnectionsRun': False,
    'actualDialOrHangupRun': False, 'sdpParser':sdp_parser, 'stateMachine':state_machine, 'argumentCases':arg_results,
    'jsonCommandValidationCases':len(cases),
    'cachedStatusStopLifecycle':{'passed':True,'elapsedSeconds':elapsed,'channelsEmptyThroughout':True},
    'sourceSHA256':{name:digest(ROOT/name) for name in ['bluetooth-call-control.mm','hfp-control-machine.hpp','test-hfp-control-machine.cpp','sdp-rfcomm-parser.h','test-sdp-rfcomm-parser.mm','validate-bluetooth-control.py']},
    'binarySHA256':digest(BIN),
}
(ROOT/'bluetooth-control-validation-20260908.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({'passed':True,'stateMachineCases':state_machine['cases'],'sdpParserCases':sdp_parser['cases'],'argumentCases':len(args_cases),'jsonValidationCases':len(cases),'actualDeviceQueriesRun':False}))
