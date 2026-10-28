#!/usr/bin/env python3
"""Update only the README code-statistics block from tracked, first-party source.

Requires cloc 2.10 (or --cloc /path/to/cloc). Does not contact a service, access
runtime data, change Git configuration, commit, or push.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
START = "<!-- CODE_STATS_START -->"
END = "<!-- CODE_STATS_END -->"
EXTENSIONS = {".swift", ".m", ".mm", ".c", ".cpp", ".h", ".hpp", ".ets",
              ".ts", ".cjs", ".py", ".sh", ".html"}
GROUPS = ["Mac 主程序与 Web 控制台", "鸿蒙手机伴侣", "Codex 插件与安装脚本",
          "底层音频、蓝牙及工具脚本", "测试代码"]


def module(path):
    p = Path(path)
    if (p.parts[0] == "Tests" or "tests" in p.parts or
            p.name.startswith(("test-", "test_")) or
            p.name.endswith(("-test.cpp", "-test.mm", "-test.m"))):
        return "测试代码"
    if path.startswith("Sources/"):
        return GROUPS[0]
    if path.startswith("HarmonyCompanion/entry/src/"):
        return GROUPS[1]
    if path.startswith("plugins/phonebridge/"):
        return GROUPS[2]
    return GROUPS[3]


def tracked_sources():
    output = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    files = sorted(set(output.decode("utf-8").rstrip("\0").split("\0")))
    return [p for p in files if Path(p).suffix in EXTENSIONS and
            "vendor" not in Path(p).parts and (ROOT / p).is_file()]


def count(files, cloc):
    with tempfile.TemporaryDirectory(prefix="phonebridge-stats-") as directory:
        listing = Path(directory) / "files.txt"
        if any("\n" in p or "\r" in p for p in files):
            raise ValueError("Source filename cannot contain a newline")
        listing.write_text("\n".join(files) + "\n", encoding="utf-8")
        command = [cloc] if cloc == "cloc" else ["perl", cloc]
        version = subprocess.check_output(command + ["--version"], text=True).strip()
        if version != "2.10":
            raise ValueError("Use the pinned cloc 2.10 for reproducible statistics")
        result = subprocess.check_output(command + [
            "--list-file=" + str(listing), "--by-file", "--json", "--quiet",
            "--skip-uniqueness", "--force-lang=TypeScript,ets"], cwd=ROOT, text=True)
    data = json.loads(result)
    rows = {}
    for path, item in data.items():
        if path in ("header", "SUM"):
            continue
        path = path.removeprefix("./")
        if path not in files or path in rows:
            raise ValueError("cloc returned an unexpected or repeated source file")
        values = [item.get(k) for k in ("code", "comment", "blank")]
        if not all(type(v) is int and v >= 0 for v in values):
            raise ValueError("cloc returned invalid counts")
        rows[path] = (item["language"], values)
    if set(rows) != set(files):
        raise ValueError("cloc did not count every selected source file")
    return rows


def render(rows):
    groups = defaultdict(lambda: [0, 0, 0, 0])
    languages = defaultdict(lambda: [0, 0, 0, 0])
    for path, (language, values) in rows.items():
        for target in (groups[module(path)], languages[language]):
            target[0] += 1
            for i, value in enumerate(values, 1):
                target[i] += value
    total = [sum(row[i] for row in groups.values()) for i in range(4)]

    def table(items, heading):
        lines = [f"| {heading} | 文件数 | 有效代码行 | 注释行 | 空行 | 总行数 |",
                 "| --- | ---: | ---: | ---: | ---: | ---: |"]
        for name, row in items:
            cells = [f"{v:,}" for v in row + [sum(row[1:])]]
            lines.append("| " + name + " | " + " | ".join(cells) + " |")
        return "\n".join(lines)

    return (START + "\n\n" + table([(g, groups[g]) for g in GROUPS] +
            [("**合计**", total)], "模块") + "\n\n<details>\n<summary>按语言查看</summary>\n\n" +
            table(sorted(languages.items(), key=lambda x: (-x[1][1], x[0])), "语言") +
            "\n\n</details>\n\n"
            "统计工具：cloc 2.10。仅统计 Git 跟踪的第一方源码，包含测试、构建脚本及 Web 界面；"
            "排除第三方 vendor、文档、配置、图片及构建产物。有效代码行不含注释和空行，"
            "总行数为三者之和；鸿蒙 `.ets` 按 TypeScript 语法统计，HTML 中的脚本计入对应文件。"
            "每次推送到 `main` 后自动更新；未发生数量变化时不产生机器人提交。\n\n" + END)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloc", default="cloc")
    args = parser.parse_args()
    readme = ROOT / "README.md"
    text = readme.read_text(encoding="utf-8")
    if text.count(START) != 1 or text.count(END) != 1 or text.index(END) < text.index(START):
        raise ValueError("README must contain exactly one ordered statistics block")
    rows = count(tracked_sources(), args.cloc)
    updated = text[:text.index(START)] + render(rows) + text[text.index(END) + len(END):]
    if updated != text:
        readme.write_text(updated, encoding="utf-8")
        print(f"Updated README statistics for {len(rows)} source files")
    else:
        print(f"README statistics unchanged ({len(rows)} source files)")


if __name__ == "__main__":
    main()
