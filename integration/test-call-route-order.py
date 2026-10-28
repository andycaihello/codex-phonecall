#!/usr/bin/env python3
from pathlib import Path

source = (Path(__file__).parents[1] / "Sources/PhoneBridge/CallSessionCoordinator.swift").read_text()
dial = source.index('request("helper_dial_ui"')
answered = source.index('guard answered', dial)
pcm_start = source.index('self.pcm.start()', dial)
deadline = source.index('self.callDeadline?.cancel()', pcm_start)

assert dial < answered < pcm_start < deadline, "PCM must start only after the phone reports an active system call"
assert 'request("connect"' not in source[source.index('func connect()'):dial], "system dial path must not create a competing raw HFP channel"
assert 'request("helper_audio"' not in source[dial:deadline], "companion must not claim the cellular audio route"
assert '手机已确认蓝牙 SCO 通话路由处于激活状态' not in source[dial:deadline], "route must remain unconfirmed without transport evidence"
print("call route ordering: PASS")
