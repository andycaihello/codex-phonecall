#!/usr/bin/env python3
"""Stage an allowlisted, unsigned-phone-source migration kit; never install it.

The Mac application retains its existing signature. Credentials and application
data are not inputs. Checksums detect accidental changes, not publisher identity.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


class ExportError(RuntimeError):
    pass


BLOCKED_NAMES = {"runtime.json", "console-settings.json", "caption-web.json", "local.properties",
                 ".mcp.json", ".env", "phone-peer.json", "config.toml"}
BLOCKED_SUFFIXES = {".p12", ".p7b", ".cer", ".pem", ".key", ".hap", ".caf", ".wav", ".pcm", ".jsonl"}
IGNORED_PARTS = {".DS_Store", "__pycache__", ".git", ".build", "node_modules", "oh_modules", "backups"}
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".h", ".hpp", ".html", ".js", ".css", ".json", ".svg", ".png"}
PHONE_SUFFIXES = {".ets", ".ts", ".json", ".json5", ".svg", ".png", ".jpg", ".webp"}
PLUGIN_SUFFIXES = {".json", ".md", ".py", ".sh", ".svg", ".png"}
MAC_FILES = ("Package.swift", "scripts/build-app.sh", "integration/build-bluetooth-call-control.sh",
             "integration/build-prepare-phone-acl.sh", "integration/bluetooth-call-control.mm",
             "integration/prepare-phone-acl.m", "integration/hfp-control-machine.hpp",
             "integration/sdp-rfcomm-parser.h", "integration/phone-identity-arguments.h",
             "integration/audio/build-pcm-bridge.sh", "integration/audio/phonebridge-pcm.mm",
             "integration/audio/pcm-dsp.hpp", "integration/audio/pcm-rings.hpp", "integration/audio/private-ipc.hpp")
PHONE_FILES = ("build.sh", "hvigorfile.ts", "oh-package.json5", "entry/build-profile.json5",
               "entry/oh-package.json5", "entry/hvigorfile.ts")


def safe_file(source):
    if any(p.is_symlink() for p in (source,) + tuple(source.parents)) or not source.is_file():
        raise ExportError("Unsupported source link or missing file: " + source.name)
    if source.name in BLOCKED_NAMES or source.suffix.lower() in BLOCKED_SUFFIXES:
        raise ExportError("Private or runtime material is not exportable: " + source.name)


def tree_files(source, suffixes=None):
    if source.is_symlink() or not source.is_dir():
        raise ExportError("Required source directory missing or linked: " + source.name)
    result = []
    for item in sorted(source.rglob("*")):
        relative = item.relative_to(source)
        if any(part in IGNORED_PARTS or ".backup" in part or part.endswith(".pyc") for part in relative.parts):
            continue
        if item.is_symlink():
            raise ExportError("Symbolic links are not supported in this kit: " + str(relative))
        if item.is_dir():
            continue
        safe_file(item)
        if suffixes is not None and item.suffix.lower() not in suffixes:
            raise ExportError("Unreviewed source file type: " + str(relative))
        result.append((item, relative))
    return result


def sanitized_phone_profile(path):
    # This project's JSON5 file deliberately uses the JSON subset. Reject future
    # syntax changes instead of using regex to strip potentially nested secrets.
    profile = json.loads(path.read_text(encoding="utf-8"))
    profile["app"].pop("signingConfigs", None)
    for product in profile["app"].get("products", []):
        product.pop("signingConfig", None)
    def check(value):
        if isinstance(value, dict):
            if any(key.lower() in {"signingconfigs", "signingconfig", "storepassword", "keypassword", "profile", "certpath", "storefile"}
                   for key in value):
                raise ExportError("Unexpected signing configuration remains in phone profile")
            for child in value.values():
                check(child)
        elif isinstance(value, list):
            for child in value:
                check(child)
    check(profile)
    return (json.dumps(profile, indent=2, ensure_ascii=False) + "\n").encode()


def production_package(data):
    text = data.decode("utf-8")
    # Fail if the known development target changes shape; never silently export
    # a manifest that still references omitted private test fixtures.
    pattern = r',\s*\.executableTarget\(name: "BridgeChecks", dependencies: \["BridgeCore"\], path: "Tests/BridgeCoreTests"\)'
    result, count = re.subn(pattern, "", text)
    if count != 1 or "Tests/" in result or 'name: "BridgeChecks"' in result:
        raise ExportError("Package targets changed; review the production export manifest")
    return result.encode()


def source_plan(root, plugin):
    root, plugin = Path(root).absolute(), Path(plugin).absolute()
    app = root / "dist/PhoneBridge.app"
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "cn.andy.phonebridge":
        raise ExportError("Unexpected Mac application identity")
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ExportError("Unexpected Mac application version")
    manifest = json.loads((plugin / ".codex-plugin/plugin.json").read_text())
    if manifest.get("name") != "phonebridge" or str(manifest.get("version", "")).split("+", 1)[0] != version:
        raise ExportError("Mac and plugin release versions must match")
    mapping = {}
    def add(source, target):
        safe_file(source)
        if target in mapping:
            raise ExportError("Duplicate export destination")
        mapping[target] = source
    def tree(source, target, suffixes=None):
        for file, relative in tree_files(source, suffixes):
            add(file, str(Path(target) / relative))
    tree(app, "Mac/PhoneBridge.app")
    add(root / "scripts/install-macos.py", "install-macos.py")
    add(root / "docs/PRODUCT-AND-MIGRATION.md", "使用与迁移说明.md")
    phone = root / "HarmonyCompanion"
    for part in ("AppScope", "entry/src", "hvigor"):
        tree(phone / part, "HarmonyCompanion/" + part, PHONE_SUFFIXES)
    for part in PHONE_FILES:
        add(phone / part, "HarmonyCompanion/" + part)
    for part in (".codex-plugin", "skills", "scripts"):
        tree(plugin / part, "plugin/phonebridge/" + part, PLUGIN_SUFFIXES)
    add(plugin / "mcp/server.py", "plugin/phonebridge/mcp/server.py")
    add(plugin / "README.md", "plugin/phonebridge/README.md")
    tree(root / "Sources", "MacSource/Sources", SOURCE_SUFFIXES)
    for part in MAC_FILES:
        add(root / part, "MacSource/" + part)
    generated = {"HarmonyCompanion/build-profile.json5": sanitized_phone_profile(phone / "build-profile.json5"),
                 "MacSource/Package.swift": production_package((root / "Package.swift").read_bytes())}
    # A release kit has its base version; installation generates a fresh cache key.
    manifest["version"] = version
    generated["plugin/phonebridge/.codex-plugin/plugin.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode()
    for key in generated:
        mapping.pop(key, None)
    # Validate every local native include transitively against the selected files.
    selected = {path.resolve() for path in mapping.values()}
    for target, path in mapping.items():
        if target.startswith("MacSource/") and path.suffix in {".h", ".hpp", ".mm", ".m"}:
            for include in re.findall(r'^\s*#\s*(?:include|import)\s*"([^"]+)"', path.read_text(), re.M):
                include_paths = (path.parent / include, root / "Sources/BluetoothShim/include" / include)
                if not any(candidate.resolve() in selected for candidate in include_paths):
                    raise ExportError("Missing local native build dependency: " + include)
    return version, mapping, generated


def verify_content(destination):
    checksums = {}
    secret_patterns = (rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", rb"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}")
    for file, relative in tree_files(destination):
        data = file.read_bytes()
        if any(re.search(pattern, data) for pattern in secret_patterns):
            raise ExportError("Credential-like material detected; staged export removed")
        checksums[str(relative)] = hashlib.sha256(data).hexdigest()
    return checksums


def export(root, plugin, output=None, dry_run=False, run=subprocess.run):
    root = Path(root).absolute()
    version, mapping, generated = source_plan(root, plugin)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(root / "dist/PhoneBridge.app")], check=True)
    name = "PhoneBridge-Migration-" + version + "-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = Path(output).absolute() if output else root / "dist"
    result = {"version": version, "files": len(mapping) + len(generated), "dryRun": dry_run,
              "includesUserData": False, "includesSigningCredentials": False,
              "publicReleaseApproved": False, "anotherMacInstallVerified": False}
    if dry_run:
        return result
    if any(p.is_symlink() for p in (output,) + tuple(output.parents)):
        raise ExportError("Refusing a linked output directory")
    output.mkdir(parents=True, exist_ok=True)
    destination, archive = output / name, output / (name + ".zip")
    if destination.exists() or archive.exists():
        raise ExportError("Output already exists")
    published = False
    with tempfile.TemporaryDirectory(prefix=".phonebridge-export-", dir=output) as temporary:
        stage = Path(temporary) / name
        stage.mkdir()
        for relative, source in mapping.items():
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        for relative, data in generated.items():
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        # Validate the actual copy, including package resources, before publication.
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(stage / "Mac/PhoneBridge.app")], check=True)
        run(["/usr/bin/xcrun", "swift", "package", "dump-package"], cwd=stage / "MacSource",
            check=True, stdout=subprocess.DEVNULL)
        # SwiftPM is permitted to create its own build/cache directory while
        # checking the manifest; it is never a migration input.
        shutil.rmtree(stage / "MacSource/.build", ignore_errors=True)
        checksums = verify_content(stage)
        (stage / "SHA256.json").write_text(json.dumps(checksums, indent=2) + "\n")
        staged_archive = Path(temporary) / (name + ".zip")
        with zipfile.ZipFile(staged_archive, "x", compression=zipfile.ZIP_DEFLATED) as stream:
            for relative in sorted(list(checksums) + ["SHA256.json"]):
                stream.write(stage / relative, str(Path(name) / relative))
        try:
            stage.rename(destination)
            published = True
            staged_archive.rename(archive)
        except BaseException:
            if published:
                shutil.rmtree(destination)
            raise
    return dict(result, directory=str(destination), archive=str(archive), files=len(checksums),
                sourceManifestValidated=True, fullSourceBuildVerified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", type=Path, default=Path.home() / "plugins/phonebridge")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    print(json.dumps(export(Path(__file__).resolve().parents[1], args.plugin, args.output, args.dry_run),
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ExportError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
