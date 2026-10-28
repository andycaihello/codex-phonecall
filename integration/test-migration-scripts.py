#!/usr/bin/env python3
"""Offline transaction tests: only temporary HOME/kit, never real Codex or App."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SKILL = Path.home() / ".codex/skills/.system/plugin-creator"
PYTHON = ROOT / "integration/plugin-validation-env/bin/python"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INSTALL = load("installer", ROOT / "scripts/install-macos.py")
EXPORT = load("exporter", ROOT / "scripts/export-migration-kit.py")
checks = []


def check(name, condition):
    assert condition, name
    checks.append(name)


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())


def checksum(kit):
    values = {str(p.relative_to(kit)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in kit.rglob("*") if p.is_file() and p.name != "SHA256.json"}
    write(kit / "SHA256.json", json.dumps(values))


class Fixture:
    def __init__(self, base, existing=False, market=True):
        self.home, self.kit = base / "home", base / "kit"
        self.home.mkdir()
        self.app = self.home / "Applications/PhoneBridge.app"
        self.plugin = self.home / "plugins/phonebridge"
        self.market = self.home / ".agents/plugins/marketplace.json"
        write(self.kit / "Mac/PhoneBridge.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "cn.andy.phonebridge"}))
        write(self.kit / "Mac/PhoneBridge.app/revision", "new")
        source = Path.home() / "plugins/phonebridge"
        for part in (".codex-plugin/plugin.json", "README.md", "mcp/server.py", "scripts/install-runtime.py", "skills/phone-call/SKILL.md"):
            write(self.kit / "plugin/phonebridge" / part, (source / part).read_bytes())
        checksum(self.kit)
        if existing:
            write(self.app / "revision", "old")
            write(self.app / "Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "cn.andy.phonebridge"}))
            write(self.plugin / ".codex-plugin/plugin.json", json.dumps({"name": "phonebridge", "version": "0.4.0+codex.old"}))
            write(self.plugin / "revision", "old")
        if market:
            entries = [{"name": "other-plugin", "source": {"source": "local", "path": "./plugins/other-plugin"}}]
            if existing:
                entries.append({"name": "phonebridge", "source": {"source": "local", "path": "./plugins/phonebridge"}})
            write(self.market, json.dumps({"name": "personal", "interface": {"displayName": "Keep This"}, "plugins": entries}))
        self.commands = []
        self.fail = None

    def run(self, argv, timeout=60, env=None):
        self.commands.append(argv)
        key = Path(argv[1]).name if len(argv) > 1 and argv[0] != "fake-codex" else argv[0]
        if key == self.fail:
            raise INSTALL.InstallError("injected failure")
        if argv[0] in ("/usr/bin/codesign", "fake-codex"):
            return "{}"
        assert env["HOME"] == str(self.home)
        return INSTALL.command(argv, timeout=timeout, env=env)

    def execute(self, dry=False, process_check=lambda: 1):
        return INSTALL.install(self.kit, self.home, SKILL, str(PYTHON), "fake-codex", dry,
                               self.run, process_check)


def expected_failure(fixture, text):
    try:
        fixture.execute()
    except INSTALL.InstallError as error:
        assert text in str(error), str(error)
        return
    raise AssertionError("expected failure")


with tempfile.TemporaryDirectory(prefix="phonebridge-migration-checks-") as temporary:
    base = Path(temporary).resolve()
    def fixture(name, **options):
        path = base / name
        path.mkdir()
        return Fixture(path, **options)

    f = fixture("dry", existing=True)
    before = {str(p.relative_to(f.home)): p.read_bytes() for p in f.home.rglob("*") if p.is_file()}
    result = f.execute(dry=True)
    after = {str(p.relative_to(f.home)): p.read_bytes() for p in f.home.rglob("*") if p.is_file()}
    check("dry-run performs no home writes or registration", before == after and result["dryRun"] and not any(c[0] == "fake-codex" for c in f.commands))

    f = fixture("fresh", market=False)
    result = f.execute()
    check("fresh official scaffold works without overwriting packaged plugin", result["installed"] and json.loads((f.plugin / ".codex-plugin/plugin.json").read_text())["mcpServers"] == "./.mcp.json")
    check("fresh market points at personal plugin source", json.loads(f.market.read_text())["plugins"][0]["source"]["path"] == "./plugins/phonebridge")
    check("new MCP config uses only fake home app and runtime", str(f.home) in (f.plugin / ".mcp.json").read_text() and str(Path.home()) not in (f.plugin / ".mcp.json").read_text())

    f = fixture("new-entry-existing-market")
    f.execute()
    market = json.loads(f.market.read_text())
    check("official scaffold preserves unrelated market entries and display name", market["interface"]["displayName"] == "Keep This" and [e["name"] for e in market["plugins"]] == ["other-plugin", "phonebridge"])

    f = fixture("upgrade", existing=True)
    original = f.market.read_bytes()
    result = f.execute()
    check("existing entry is reused without scaffold or market edit", f.market.read_bytes() == original and not any("create_basic_plugin.py" in " ".join(c) for c in f.commands))
    check("upgrade uses fresh official cachebuster and validator", "+codex." in json.loads((f.plugin / ".codex-plugin/plugin.json").read_text())["version"] and any("validate_plugin.py" in " ".join(c) for c in f.commands))
    check("old app and plugin backups retained", len(result["backups"]) == 2 and all(Path(p).is_dir() for p in result["backups"].values()))

    for failed_step in ("install-runtime.py", "validate_plugin.py", "update_plugin_cachebuster.py"):
        f = fixture("fail-" + failed_step, existing=True)
        original = f.market.read_bytes()
        f.fail = failed_step
        expected_failure(f, "Local replacements restored")
        check("rollback on " + failed_step, (f.app / "revision").read_text() == "old" and (f.plugin / "revision").read_text() == "old" and f.market.read_bytes() == original and not any(c[0] == "fake-codex" for c in f.commands))

    f = fixture("registration-failure", existing=True)
    f.fail = "fake-codex"
    expected_failure(f, "Codex cache state is unverified")
    check("CLI failure retains recoverable new files and old backups truthfully", (f.app / "revision").read_text() == "new" and len(list(f.app.parent.glob("*.backup-*"))) == 1 and len(list(f.plugin.parent.glob("*.backup-*"))) == 1)

    f = fixture("wrong-source", existing=True)
    value = json.loads(f.market.read_text())
    value["plugins"][-1]["source"]["path"] = "./plugins/someone-else"
    f.market.write_text(json.dumps(value))
    expected_failure(f, "another source")
    check("wrong marketplace source rejected before replacement", (f.app / "revision").read_text() == "old" and not f.commands)

    f = fixture("running", existing=True)
    try:
        f.execute(process_check=lambda: 0)
        raise AssertionError("running app accepted")
    except INSTALL.InstallError:
        check("running application is not stopped or replaced", (f.app / "revision").read_text() == "old")

    f = fixture("integrity")
    write(f.kit / "unlisted-file", "unexpected")
    expected_failure(f, "inventory differs")
    check("unlisted kit file fails checksum inventory", not f.commands)

    f = fixture("symlink")
    f.app.parent.mkdir(parents=True)
    f.app.symlink_to(base / "somewhere-else")
    expected_failure(f, "symbolic-link")
    check("linked target rejected before mutations", not f.commands)

    profile = base / "phone-profile.json5"
    profile.write_text(json.dumps({"app": {"signingConfigs": [{"material": {"storePassword": "FAKE-SECRET"}}], "products": [{"name": "default", "signingConfig": "debug"}]}, "modules": []}))
    sanitized = EXPORT.sanitized_phone_profile(profile)
    check("phone signing profile and nested material omitted", b"FAKE-SECRET" not in sanitized and b"signingConfig" not in sanitized and b"default" in sanitized)
    package = EXPORT.production_package((ROOT / "Package.swift").read_bytes())
    check("production manifest retains web resources and drops private tests", b'Resources/Web' in package and b"Tests/" not in package)
    secret = base / "secret-stage"
    secret.mkdir()
    write(secret / "unexpected.txt", "-----BEGIN " + "PRIVATE KEY-----")
    try:
        EXPORT.verify_content(secret)
        raise AssertionError("private key accepted")
    except EXPORT.ExportError:
        check("credential scan rejects private key material", True)
    linked = base / "linked-source"
    linked.mkdir()
    (linked / "x.swift").symlink_to(profile)
    try:
        EXPORT.tree_files(linked, EXPORT.SOURCE_SUFFIXES)
        raise AssertionError("source link accepted")
    except EXPORT.ExportError:
        check("export refuses linked source files", True)

    output = base / "failed-export"
    def fail_manifest(argv, **kwargs):
        if argv[0] == "/usr/bin/xcrun":
            raise subprocess.CalledProcessError(1, argv)
        return subprocess.CompletedProcess(argv, 0)
    try:
        EXPORT.export(ROOT, Path.home() / "plugins/phonebridge", output=output, run=fail_manifest)
        raise AssertionError("failed manifest was published")
    except subprocess.CalledProcessError:
        check("failed source-manifest validation removes staged export", output.is_dir() and list(output.iterdir()) == [])

report = {"passed": len(checks), "checks": checks,
          "realAppLaunched": False, "realCodexRegistration": False, "realMarketplaceChanged": False,
          "officialScaffoldCachebusterValidator": True, "codesignAndCodexInInstallerTests": "mocked"}
(ROOT / "integration/migration-scripts-offline-validation-20260909.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
