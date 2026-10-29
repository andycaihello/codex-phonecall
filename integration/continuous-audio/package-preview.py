#!/usr/bin/env python3
"""Stage a reviewable candidate and driver installer; do not install/launch."""
from pathlib import Path
import hashlib, json, plistlib, shutil, subprocess

ROOT = Path(__file__).resolve().parents[2]
LOCAL = Path(__file__).resolve().parent
source_app = ROOT / 'dist/PhoneBridge.app'
source_info = plistlib.loads((source_app / 'Contents/Info.plist').read_bytes())
version = source_info['CFBundleShortVersionString']
OUT = ROOT / f'dist/PhoneBridge-Continuous-{version}'
OUT.mkdir(parents=True, exist_ok=True)
binary_dir = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip())
app = OUT / 'PhoneBridge.app'
subprocess.run(['ditto', str(source_app), str(app)], check=True)
shutil.copy2(binary_dir / 'PhoneBridge', app / 'Contents/MacOS/PhoneBridge')
subprocess.run(['strip', '-S', str(app / 'Contents/MacOS/PhoneBridge')], check=True)
subprocess.run(['ditto', str(ROOT / 'Sources/PhoneBridge/Resources/Web'), str(app / 'Contents/Resources/Web')], check=True)
plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
info['NSMicrophoneUsageDescription'] = '启用连续语音时，读取本机麦克风与你交流，或读取你选定手机的蓝牙通话音频；不保存原始录音。'
plist.write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--verify', '--strict', str(app / 'Contents/Helpers/PhoneBridgePCM.app')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

payload = LOCAL / 'build/installer-root'
drivers = payload / 'Library/Audio/Plug-Ins/HAL'
drivers.mkdir(parents=True, exist_ok=True)
for role in ['Input', 'Output']:
    name = 'PhoneBridgeVoice' + role + '.driver'
    subprocess.run(['ditto', str(LOCAL / 'build' / name), str(drivers / name)], check=True)
pkg = OUT / 'PhoneBridge-Continuous-Audio-0.1.1.pkg'
scripts = LOCAL / 'build/installer-scripts'
scripts.mkdir(parents=True, exist_ok=True)
postinstall = scripts / 'postinstall'
postinstall.write_text('''#!/bin/sh
# User-chosen installation reloads audio as documented in the README.
# Signal only the uniquely identified system audio daemon, never reboot macOS.
audio_candidate_pid="$(/usr/bin/pgrep -x coreaudiod || true)"
case "$audio_candidate_pid" in ''|*[!0-9]*) exit 0;; esac
audio_candidate_owner="$(/bin/ps -p "$audio_candidate_pid" -o user= | /usr/bin/xargs)"
audio_candidate_path="$(/bin/ps -p "$audio_candidate_pid" -o comm= | /usr/bin/xargs)"
if [ "$audio_candidate_owner" = "_coreaudiod" ] && [ "$audio_candidate_path" = "/usr/sbin/coreaudiod" ]; then
  /bin/kill -TERM "$audio_candidate_pid" || true
fi
exit 0
''')
postinstall.chmod(0o755)
subprocess.run(['pkgbuild', '--root', str(payload), '--ownership', 'recommended', '--identifier',
                'cn.andy.phonebridge.audio.cables', '--version', '0.1.1', '--install-location', '/', '--scripts', str(scripts),
                '--filter', r'(^|/)\._', str(pkg)], check=True)
(OUT / 'READ-ME-FIRST.txt').write_text(f'PhoneBridge {version} 开发构建\n\n请先阅读项目 README。App 与驱动均为本地开发签名，未做 Developer ID 公证。\n本机已验证功能不能代替这台新设备的实际通话验收。\n\n1. 退出旧版 App，将 PhoneBridge.app 安装到 ~/Applications/PhoneBridge.app。\n2. Codex 自动语音需要另行安装 README 中的本机语音运行时；不需要虚拟音频驱动。\n3. 如使用桌面内置连续语音，在空闲时安装 PhoneBridge-Continuous-Audio-0.1.1.pkg，需管理员验证。\n   安装会重载系统音频，暂时中断音频和语音聊天；不会重启电脑。\n4. 为自己的手机构建签名伴侣 App，配对并选择两端设备。\n5. 按 README 生成本机 MCP 配置、登记本地市场、在 Codex 安装插件。\n\n内置语音不使用本项目 API 密钥，但声音仍接入 Codex 语音服务，并非全程离线。\nAPI 模式需要另行配置自己的 API 账户和本轮上传/费用同意。\n常规路径不保存原始录音。Apple 示例许可证保留在两个驱动内。\n')

manifest = {'installed': False, 'launched': False, 'version': version, 'reloadAudioServiceAfterInstall': True,
            'packageSHA256': hashlib.sha256(pkg.read_bytes()).hexdigest(),
            'macBinarySHA256': hashlib.sha256((app / 'Contents/MacOS/PhoneBridge').read_bytes()).hexdigest(),
            'pcmHelperRebuilt': False, 'freshBuildLiveCallsVerified': False}
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(str(OUT))
