#!/bin/sh
set -eu
audio_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
audio_app="$audio_dir/PhoneBridgePCM.app"
mkdir -p "$audio_app/Contents/MacOS"
cat > "$audio_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.phonebridge.PCMBridge</string>
<key>CFBundleName</key><string>PhoneBridge PCM Audio</string>
<key>CFBundleExecutable</key><string>phonebridge-pcm</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>在你启动通话助手后，读取指定手机的蓝牙通话声音，经本机私有连接交给 PhoneBridge。经你在主程序明确同意，主程序可将声音发送给 OpenAI 实时语音服务并播放回答。本音频助手不保存录音；每次通话最长五分钟。</string>
</dict></plist>
PLIST
xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wall -Wextra -Werror \
  "$audio_dir/phonebridge-pcm.mm" -framework Foundation -framework AppKit -framework AVFoundation -framework CoreAudio \
  -Wl,-sectcreate,__TEXT,__info_plist,"$audio_app/Contents/Info.plist" \
  -o "$audio_app/Contents/MacOS/phonebridge-pcm"
codesign --force --sign - "$audio_app"
codesign --verify --strict "$audio_app"
printf '%s\n' "$audio_app"
