# PhoneBridge local PCM helper

This independent normal AppKit application transfers PCM between **only** the verified phone's split CoreAudio endpoints and a private local coordinator. It does not dial, perform speech recognition, connect to the Internet, save audio, change a device format/default route, or fall back to a built-in microphone/speaker. The frozen successful diagnostic App is unchanged.

Build: `sh integration/audio/build-pcm-bridge.sh` from the PhoneBridge directory. Output: `integration/audio/PhoneBridgePCM.app`, executable `Contents/MacOS/phonebridge-pcm`, bundle identifier `local.phonebridge.PCMBridge`, version 0.1.0/build 1. This is ordinary ad-hoc signing without entitlements. Use normal LaunchServices/NSWorkspace to start the App so its own microphone permission and returned live application identity apply.

## Launch contract

```text
--microphone-permission-status --report /absolute/private/new-status.json
--request-microphone-permission --report /absolute/private/new-permission.json
--bridge --socket /absolute/private/coordinator.sock --token-file /absolute/private/token --max-seconds 300 --report /absolute/private/new-session.json
```

Permission actions never query audio devices or start IO. Status is read-only; request waits at most 45 seconds and only prompts if currently not determined. Stages are `permission-status-only` and `permission-only`; `authorizationBefore`, `authorizationAfter`, `permissionRequested`, and `cleanupVerified` are truthful. The bridge checks existing authorization and fails before device access if not authorized; it never requests permission during a call.

For a command-line owner that must use normal LaunchServices, build the separate permission-only supervisor with `sh integration/audio/build-pcm-permission-launcher.sh`. It does not modify/rebuild the frozen PCM App. Example argument contract (the private directory and App must exist, both JSON files must be new):

```text
integration/audio/pcm-permission-launcher --application /absolute/PhoneBridgePCM.app --report /absolute/private/native.json --status /absolute/private/launch.json --limit 55 -- --microphone-permission-status
integration/audio/pcm-permission-launcher --application /absolute/PhoneBridgePCM.app --report /absolute/private/new-native.json --status /absolute/private/new-launch.json --limit 55 -- --request-microphone-permission
```

Exactly those two native flags are allowed, one per run; bridge/audio/custom flags are rejected. `--validate-launch-args` before `--` checks bundle, paths and strict arguments without launching or querying permissions. Launch limit is 1..55 seconds. The supervisor keeps the exact new NSWorkspace-returned bundle/path/PID, excludes pre-existing instances, monitors its parent and forwards TERM only to its owned App, giving three seconds before KILL and one more second to observe termination. An outstanding asynchronous launch gets an additional bounded eight-second window; completion near the end can need four more seconds for owned cleanup, so an outer supervisor should allow **limit + 12 seconds**. Unknown pending cancellation is reported as unverified, never claimed cancelled. No process-name/bundle-wide kill is used.

The native report is read only from its fresh owned 0600 regular file. Exit zero requires a shape-valid permission result; a request additionally requires `authorizationAfter: authorized`. Launcher's cleanup describes its App ownership/termination separately from the native report. A fast read-only status result may return zero when the returned App is already terminated and its PID cannot be established, but then `ownedAppVerified` and launcher `cleanupVerified` stay false with an explicit read-only-result scope. This exception is never used for requests or to authorize signalling a PID. LaunchServices does not expose the native exit code (`nativeExitCode: null`). Pure validation evidence: `permission-launcher-validation.json`.

`--validate-args` alongside any one action parses only, before AppKit/TCC/files/socket/CoreAudio work. `--max-seconds` is an integer 0..2147483647 (default 0), only for bridge mode. Zero means no fixed total IO duration; positive values specify an owner-requested duration. All paths are absolute and standardized. Report is optional metadata only, created exclusively with mode 0600 inside an existing owner-only 0700 directory; existing files are rejected. Coordinator should always supply one to independently verify cleanup.

Coordinator creates a unique 0700 directory containing an owned 0600 AF_UNIX listening socket and a regular owned 0600 token file (exactly 64 hexadecimal characters, optionally one trailing newline). Socket and token must be in the same directory. No symlink at socket/token/parent is accepted. Socket path must fit macOS `sockaddr_un.sun_path`. Both processes verify peer uid/PID; native uses public `getpeereid` and `LOCAL_PEERPID`. Token is sent only through this private socket, never stdout, metadata reports or argv. Coordinator must independently authenticate token, kernel peer PID, and its owned NSWorkspace returned App before sending `start`.

Connection is bounded to five seconds. After hello the helper sends no further event and waits at most ninety seconds for `start` or `stop`, allowing the coordinator to dial, await the answer and connect its voice session. This preparation window performs no device queries or IO, and peer exit/EOF, stop and signals still terminate it promptly. A ninety-three-second watchdog bounds a blocked preparation operation. The coordinator must arrange Bluetooth call routing and explicit cloud consent/API readiness before sending `start`. An optional positive IO duration begins only with the first successfully started audio procedure; 0 leaves total duration unlimited. The App has a normal AppKit launch lifecycle, not a CLI process posing as an App.

## JSONL protocol 1

Events use `type`; commands use `op`. One UTF-8 JSON object per newline; command line limit 96 KiB. Strings/PCM/token must not be copied into general logs.

| Direction | Message |
|---|---|
| Helper → coordinator | `{"type":"hello","protocol":1,"token":"64-hex-secret","pid":123,"generation":0}` |
| Coordinator → helper | `{"op":"start"}` |
| Helper → coordinator | `{"type":"ready","generation":0,"input_sample_rate":24000,"output_sample_rate":24000,"device_sample_rate":8000,"channels":1,"format":"pcm16-little-endian",...}` |
| Helper → coordinator | `{"type":"input_audio","audio":"base64 PCM16LE","frames":2400,"sample_rate":24000,"channels":1,"sequence":0,"elapsed_seconds":0.1}` |
| Coordinator → helper | `{"op":"output_audio","generation":0,"response_id":"resp-1","item_id":"item-1","content_index":0,"audio":"base64 PCM16LE mono 24000 Hz"}` |
| Coordinator → helper | `{"op":"output_end","generation":0,"response_id":"resp-1","item_id":"item-1","content_index":0}` |
| Helper → coordinator | `{"type":"playback","generation":0,"response_id":"resp-1","item_id":"item-1","content_index":0,"played_frames8000":800,"audio_end_ms":100,"device_frames_submitted":843,"scope":"HAL-submitted-not-audible-confirmed",...}` |
| Coordinator → helper | `{"op":"clear_output","generation":1}` |
| Helper → coordinator | `{"type":"clear_ack","generation":1,"scope":"Older queued frames discarded; previously submitted HAL buffers cannot be recalled"}` |
| Coordinator → helper | `{"op":"stop"}` |
| Helper → coordinator | `{"type":"stopped","generation":1,"cleanupVerified":true,"success":true,"stop_reason":"stop-command","error":null}` |

`ready` proves both exact endpoint IOProcs returned Start=0, not that a first incoming buffer or remote speech has arrived. Input events are emitted after actual input callbacks supply a full 800-frame 8 kHz block; the converter makes 2400 frames at 24 kHz (about 100 ms). Source filter delay is 5.333 ms. No fabricated incoming silence event is generated when callbacks are absent.

Each output chunk contains 1..24000 frames (at most one second). Audio bytes are strict signed PCM16 little-endian mono 24 kHz. IDs are 1..128 ASCII letters/digits/underscore/colon/hyphen; content index is an integer 0..1024. One open item at a time: finish or clear before starting the next. At most 512 item records per session. `output_end` must be sent once per item/content index and flushes only the finite FIR tail, never loops audio.

Output queue is bounded to ten seconds of 8 kHz frames including FIR tail, with 87 frames reserved while accepting chunks. Queue overflow fails the session instead of growing memory. Playback progress comes from frames actually submitted by the output callback, not received WebSocket bytes or timer estimates. `device_frames_submitted` is the raw per-item HAL frame count; `played_frames8000` is the monotonic source content position after compensating the 128/24000-second FIR delay and capping at the item's accepted source duration. `audio_end_ms = floor(played_frames8000 / 8)`. This is the best local submission boundary for truncation; hardware buffering and remote audibility are not confirmed.

Every output/clear command requires an integer generation, not a boolean. Clear must strictly increase it. The callback zeroes a buffer if it observes a generation change mid-render, discards all queued older frames, then publishes `clearObserved`. Main sends changed playback positions before `clear_ack`. **Wait for the matching clear_ack before sending new-generation chunks.** Stale/future/not-yet-acknowledged chunks receive `output_rejected` and never enter the playback queue. A HAL buffer submitted before the clear was observed cannot be recalled.

## Route, real-time work, and cleanup

Exact endpoints: `C4-5A-86-FB-85-4E:input` and `C4-5A-86-FB-85-4E:output`, both named `CAI SHENGLI 80 Pro`, alive, Bluetooth transport, unique distinct device IDs. Input must have one input/zero output channels; output the reverse. Each must expose one packed float32 little-endian mono 8000 Hz virtual stream. These properties are rechecked every 250 ms. There is no route substitution, HogMode, format mutation, SCO control, or default-device mutation.

The realtime callbacks only use preallocated SPSC arrays, zero/copy/float samples and lock-free atomic counters. They do not allocate, call Foundation/Speech, touch a file/socket, query HAL, or take locks. Conversion, base64, JSON and IPC occur on the non-realtime App main loop. A 257-tap normalized Blackman-windowed sinc (3.5 kHz cutoff at 24 kHz) filters before 3:1 decimation and after zero insertion with gain 3 for interpolation. Converter state persists across chunks and resets on item boundaries/clear.

The incoming ring holds two seconds. Incoming IPC messages older than two seconds unsent, a 256 KiB outgoing queue, malformed buffers/commands, route changes, peer disconnect/death, SIGTERM/INT, or stop terminate IO. Stop does not flush residual microphone samples; wholly unsent input messages are dropped. If an input JSON line was partly sent, the socket closes rather than completing that PCM transmission or corrupting framing; the report remains the cleanup authority.

An explicitly requested positive duration starts at the first successfully started IOProc. With 0, a moving ten-second main-loop health watchdog replaces a total-IO deadline. Setup, peer/parent death and cleanup remain bounded; signal/peer death also starts a three-second hard exit deadline. Stop is called only for owned successfully started IOProc IDs; Destroy is attempted for every non-null returned ID. No existing process/device client is stopped. If Stop/Destroy fails, the report sets cleanup false and `_Exit` occurs while callback context and sample arrays remain alive. If an API blocks until the watchdog, hard exit reports cleanup unverified to stderr; it cannot promise native Stop succeeded. Root still supervises only the NSWorkspace-returned owned App and hangs up the owned phone call separately.

Normal final metadata is `stage: bridge-finished`, with both endpoint Create/Start/Stop/Destroy codes, `fullDuplexStarted`, `success`, `cleanupVerified`, identity status, generation, counts, elapsed IO time and stop reason. No token, PCM, transcription or recording is stored. Early rejection can leave `stage: bridge-rejected` with a specific error and IO false.

## Validation and remaining boundary

Offline tests cover filtering/alias suppression, exact streaming counts and chunk invariance, reset, bounded ring overflow, 200000-frame concurrent SPSC publication, HAL submission counters, generation flush/ack, stale chunks, finite tail/truncation bounds, stop silence, and parse-only rejection. See `offline-validation.json` for source hashes and results. No real App launch, permission request, socket connection, microphone, phone call or playback is part of these tests. Normal NSWorkspace ownership/TCC and live duplex latency/route/clear behavior still require the root's explicit controlled integration test after this build is frozen.
