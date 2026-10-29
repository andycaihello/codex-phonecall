#!/usr/bin/env python3
"""Install only the optional, private WebRTC runtime; never touches Codex auth."""
from pathlib import Path
import os
import subprocess
import sys
import venv


def main():
    if sys.version_info < (3, 11):
        raise SystemExit("需要 Python 3.11 或以上版本。")
    root = Path.home() / "Library/Application Support/PhoneBridge/codex-voice-runtime"
    if root.is_symlink():
        raise SystemExit("运行时目录不能是符号链接。")
    root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    venv.EnvBuilder(with_pip=True).create(root)
    os.chmod(root, 0o700)
    python = root / "bin/python3"
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                    "--only-binary=:all:", "aiortc==1.14.0", "av==16.1.0"], check=True)
    subprocess.run([str(python), "-c", "import aiortc,av;print('Codex 语音 WebRTC 运行时已就绪。')"], check=True)


if __name__ == "__main__":
    main()
