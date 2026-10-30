#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
bash integration/build-bluetooth-call-control.sh
sh integration/build-prepare-phone-acl.sh
python3 scripts/build-cached-pcm.py
sh integration/audio/build-pcm-permission-launcher.sh
swift build -c release
task_bin="$(swift build -c release --show-bin-path)"
task_app="$task_root/dist/PhoneBridge.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources" "$task_app/Contents/Helpers"
cp "$task_bin/PhoneBridge" "$task_app/Contents/MacOS/PhoneBridge"
# SwiftPM release output retains linker debug references to the build user's
# source/object paths. Remove those references before signing the distributable.
/usr/bin/strip -S "$task_app/Contents/MacOS/PhoneBridge"
cp integration/bluetooth-call-control "$task_app/Contents/MacOS/bluetooth-call-control"
cp integration/prepare-phone-acl "$task_app/Contents/MacOS/prepare-phone-acl"
cp integration/audio/pcm-permission-launcher "$task_app/Contents/MacOS/pcm-permission-launcher"
ditto Sources/PhoneBridge/Resources/Web "$task_app/Contents/Resources/Web"
ditto Sources/PhoneBridge/Resources/Audio "$task_app/Contents/Resources/Audio"
mkdir -p "$task_app/Contents/Resources/CodexVoice"
cp scripts/codex_voice_runtime.py "$task_app/Contents/Resources/CodexVoice/codex_voice_runtime.py"
cp scripts/codex_voice_captions.py "$task_app/Contents/Resources/CodexVoice/codex_voice_captions.py"
ditto integration/audio/PhoneBridgePCM.app "$task_app/Contents/Helpers/PhoneBridgePCM.app"
codesign --verify --strict "$task_app/Contents/Helpers/PhoneBridgePCM.app"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhoneBridge</string>
<key>CFBundleIdentifier</key><string>cn.andy.phonebridge</string>
<key>CFBundleName</key><string>PhoneBridge</string>
<key>CFBundleDisplayName</key><string>通话桥</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.4</string>
<key>CFBundleVersion</key><string>67</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>连接你选择的手机，通过蓝牙免提协议控制电话。</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>连接你选择的手机蓝牙免提服务。</string>
<key>NSMicrophoneUsageDescription</key><string>启用连续语音时，读取本机麦克风与你交流，或读取你选定手机的蓝牙通话音频；不保存原始录音。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>将手机蓝牙通话输入在本机转为实时字幕，并交给发起通话的 Codex 对话。</string>
</dict></plist>
PLIST
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
printf '%s\n' "$task_app"
