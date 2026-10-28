#!/usr/bin/env python3
"""Read the installed companion's last diagnostic using its public onDump hook."""
import argparse
import pathlib
import re
import subprocess
import sys

BUNDLE = 'cn.andy.phonebridge.companion'
DEFAULT_HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'


def main():
    parser = argparse.ArgumentParser(description='读取鸿蒙通话诊断 App 的最近一次检查结果')
    parser.add_argument('--hdc', default=DEFAULT_HDC)
    parser.add_argument('--device', help='连接多个设备时显式指定 HDC 设备 ID')
    args = parser.parse_args()
    def execute(*parts):
        result = subprocess.run([args.hdc, *parts], capture_output=True, text=True, timeout=15, check=True)
        return result.stdout
    targets = [line.strip() for line in execute('list', 'targets').splitlines()
               if line.strip() and not line.startswith('[')]
    if args.device:
        if args.device not in targets: raise RuntimeError('指定手机尚未连接 HDC。')
        device = args.device
    elif len(targets) == 1:
        device = targets[0]
    else:
        raise RuntimeError('需要恰好一台 HDC 设备；多台设备请用 --device 指定。')
    base = ['-t', device, 'shell', 'aa', 'dump']
    abilities = execute(*base, '-a')
    blocks = re.split(r'(?=    Mission ID #)', abilities)
    marker = 'mission name #[#' + BUNDLE + ':'
    matches = [block for block in blocks if marker in block.splitlines()[0]]
    if len(matches) != 1: raise RuntimeError('未找到唯一的诊断 App 运行实例，请先打开手机 App。')
    record = re.search(r'AbilityRecord ID #(\d+)', matches[0])
    if record is None: raise RuntimeError('诊断 App 未返回有效的运行记录 ID。')
    report = execute(*base, '-i', record[1], '-c')
    # Never expose other applications' activity records or diagnostic dumps.
    lines = [line.strip() for line in report.splitlines() if line.strip().startswith('PhoneBridgeProbe:')]
    if not lines: raise RuntimeError('未收到诊断结果，请确认手机安装的是 0.1.1 或更高版本。')
    print('\n'.join(lines))
    print('这是报告中时间对应的检查结果；需要更新时请在手机点击检查。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('PhoneBridge: ' + str(error), file=sys.stderr)
        sys.exit(1)
