#!/usr/bin/env python3
"""Inspect and operate HarmonyOS 7 Text Call through an authorized HDC link.

This tool never dials or hangs up. It only reads the current accessibility tree,
clicks a uniquely named control, or types into the currently visible call UI.
"""
import argparse
import json
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import time

DEFAULT_HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'
ALLOWED_BUNDLES = {
    'com.ohos.callui',
    'com.huawei.hmos.callaiservice',
    'com.huawei.hmos.callsetting',
    'com.huawei.hmos.settings',
    'com.ohos.settings',
    'com.ohos.sceneboard',
}


def run(hdc: str, target: str | None, *args: str, timeout: int = 15) -> str:
    command = [hdc]
    if target:
        command += ['-t', target]
    command += list(args)
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0 or result.stdout.startswith('[Fail]'):
        raise RuntimeError((result.stderr or result.stdout or 'HDC command failed').strip())
    return result.stdout


def connected_target(hdc: str, requested: str | None) -> str:
    if requested:
        return requested
    rows = []
    for line in run(hdc, None, 'list', 'targets', '-v').splitlines():
        parts = line.split()
        if parts and 'Connected' in parts:
            rows.append(parts[0])
    if len(rows) != 1:
        raise RuntimeError('需要恰好一个已连接的 HDC 目标；请用 --target 指定。')
    return rows[0]


def dump_layout(hdc: str, target: str) -> dict:
    stamp = f'phonebridge-text-call-{int(time.time() * 1000)}.json'
    remote = '/data/local/tmp/' + stamp
    with tempfile.TemporaryDirectory(prefix='phonebridge-') as folder:
        local = pathlib.Path(folder) / stamp
        try:
            run(hdc, target, 'shell', 'uitest', 'dumpLayout', '-p', remote)
            run(hdc, target, 'file', 'recv', remote, str(local))
            return json.loads(local.read_text())
        finally:
            try:
                run(hdc, target, 'shell', 'rm', remote)
            except (OSError, RuntimeError, subprocess.SubprocessError):
                pass


def nodes(tree: dict):
    stack = [(tree, '')]
    while stack:
        node, inherited_bundle = stack.pop()
        attributes = dict(node.get('attributes', {}))
        bundle = attributes.get('bundleName', '') or inherited_bundle
        if bundle:
            attributes['bundleName'] = bundle
        if attributes:
            yield attributes
        stack.extend((child, bundle) for child in reversed(node.get('children', [])))


def visible_rows(tree: dict) -> list[dict]:
    rows = []
    for item in nodes(tree):
        if item.get('visible') == 'false':
            continue
        bundle = item.get('bundleName', '')
        text = item.get('text', '') or item.get('originalText', '') or item.get('description', '')
        if bundle in ALLOWED_BUNDLES and (text or item.get('clickable') == 'true'):
            rows.append({key: item.get(key, '') for key in
                         ('bundleName', 'type', 'text', 'originalText', 'description', 'bounds',
                          'clickable', 'enabled', 'focused', 'id')})
    return rows


def center(bounds: str) -> tuple[int, int]:
    numbers = [int(value) for value in re.findall(r'-?\d+', bounds)]
    if len(numbers) != 4:
        raise RuntimeError('控件没有有效坐标。')
    return (numbers[0] + numbers[2]) // 2, (numbers[1] + numbers[3]) // 2


def click_label(hdc: str, target: str, label: str) -> None:
    if not label or len(label) > 40:
        raise RuntimeError('控件文字需为 1–40 个字符。')
    matches = []
    for item in nodes(dump_layout(hdc, target)):
        values = {item.get('text', ''), item.get('originalText', ''), item.get('description', '')}
        if label in values and item.get('visible') != 'false' and item.get('enabled') != 'false':
            bundle = item.get('bundleName', '')
            if bundle in ALLOWED_BUNDLES:
                matches.append(item)
    if len(matches) != 1:
        raise RuntimeError(f'当前界面中找到 {len(matches)} 个精确匹配“{label}”的安全控件。')
    x, y = center(matches[0].get('bounds', ''))
    run(hdc, target, 'shell', 'uitest', 'uiInput', 'click', str(x), str(y))


def type_text(hdc: str, target: str, text: str) -> None:
    clean = text.strip()
    if not clean or len(clean) > 500 or any(ord(char) < 32 for char in clean):
        raise RuntimeError('输入文字需为 1–500 个可见字符。')
    visible = visible_rows(dump_layout(hdc, target))
    call_ui = any(row['bundleName'] in {'com.ohos.callui', 'com.huawei.hmos.callaiservice'} for row in visible)
    if not call_ui:
        raise RuntimeError('当前前台不是系统通话或文本通话界面，已拒绝输入。')
    # HDC executes the remainder through the device shell. Quote the complete
    # text so punctuation and spaces cannot become shell syntax.
    command = 'uitest uiInput text ' + shlex.quote(clean)
    run(hdc, target, 'shell', command)


def search_settings(hdc: str, target: str, query: str) -> None:
    clean = query.strip()
    if not clean or len(clean) > 40 or any(ord(char) < 32 for char in clean):
        raise RuntimeError('设置搜索文字需为 1–40 个可见字符。')
    tree = dump_layout(hdc, target)
    visible = list(nodes(tree))
    if not any(item.get('bundleName') == 'com.huawei.hmos.settings' for item in visible):
        raise RuntimeError('当前前台不是系统设置，已拒绝输入。')
    fields = [item for item in visible
              if item.get('id') in {'homPageSearchInput', '__SearchField__homPageSearchInput'}
              and item.get('visible') != 'false' and item.get('enabled') != 'false']
    if not fields:
        raise RuntimeError('当前设置页面没有找到首页搜索框。')
    # Prefer the concrete SearchField over its containing Search node.
    field = next((item for item in fields if item.get('type') == 'SearchField'), fields[0])
    x, y = center(field.get('bounds', ''))
    command = f'uitest uiInput inputText {x} {y} ' + shlex.quote(clean)
    run(hdc, target, 'shell', command)


def main() -> None:
    parser = argparse.ArgumentParser(description='HarmonyOS 7 文本通话控制（不负责拨号）')
    parser.add_argument('--hdc', default=DEFAULT_HDC)
    parser.add_argument('--target')
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('inspect')
    click = sub.add_parser('click'); click.add_argument('--label', required=True)
    typing = sub.add_parser('type'); typing.add_argument('--text', required=True)
    search = sub.add_parser('search-settings'); search.add_argument('--text', required=True)
    args = parser.parse_args()
    target = connected_target(args.hdc, args.target)
    if args.action == 'inspect':
        rows = visible_rows(dump_layout(args.hdc, target))
        print(json.dumps({'target': target, 'controls': rows}, ensure_ascii=False, indent=2))
    elif args.action == 'click':
        click_label(args.hdc, target, args.label)
        print('已点击唯一匹配的系统控件；请重新 inspect 核对结果。')
    elif args.action == 'type':
        type_text(args.hdc, target, args.text)
        print('文字已输入当前系统文本通话界面；发送前仍需读取界面确认。')
    else:
        search_settings(args.hdc, target, args.text)
        print('已在系统设置中输入搜索文字；请重新 inspect 核对结果。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print('PhoneBridge Text Call: ' + str(error), file=sys.stderr)
        sys.exit(1)
