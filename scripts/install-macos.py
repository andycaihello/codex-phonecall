#!/usr/bin/env python3
"""Install this user's kit without launching apps, requesting permissions or calling.

Local replacements are rolled back before Codex registration. Once `plugin add`
has started its cache state cannot be proved atomic: keep the new local files and
backups and report a retry command instead of claiming a complete rollback.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


class InstallError(RuntimeError):
    pass


def command(argv, timeout=60, env=None):
    # Helper output can include local paths; never include raw stderr in errors.
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout, env=env)
    if result.returncode:
        raise InstallError("Command failed: " + Path(argv[0]).name +
                           " (exit " + str(result.returncode) + ")")
    return result.stdout.strip()


def no_links(path):
    for component in (path,) + tuple(path.parents):
        if component.is_symlink():
            raise InstallError("Refusing a symbolic-link installation path")


def validate_tree(path):
    no_links(path)
    if not path.is_dir():
        raise InstallError("Required kit directory is missing: " + path.name)
    for item in path.rglob("*"):
        if item.is_symlink() or not (item.is_file() or item.is_dir()):
            raise InstallError("Kit contains an unsupported link or special file")


def file_bytes(path):
    return path.read_bytes() if path.exists() else None


def validate_marketplace(path, plugin_target):
    """Only reuse an entry already pointing at the default personal source."""
    no_links(path)
    original = file_bytes(path)
    if original is None:
        return None, False
    payload = json.loads(original)
    if not isinstance(payload, dict) or not isinstance(payload.get("plugins"), list):
        raise InstallError("Invalid personal marketplace; no files changed")
    matches = [entry for entry in payload["plugins"]
               if isinstance(entry, dict) and entry.get("name") == "phonebridge"]
    if len(matches) > 1:
        raise InstallError("Duplicate phonebridge marketplace entries; no files changed")
    if matches:
        source = matches[0].get("source", {})
        if not isinstance(source, dict) or source.get("source") != "local" or \
                source.get("path") not in ("./plugins/phonebridge", str(plugin_target)):
            raise InstallError("Existing phonebridge entry uses another source; no files changed")
    return original, bool(matches)


def verify_checksums(kit):
    manifest = kit / "SHA256.json"
    if not manifest.is_file() or manifest.is_symlink():
        raise InstallError("Kit SHA256.json is missing")
    expected = json.loads(manifest.read_text(encoding="utf-8"))
    if not isinstance(expected, dict) or not expected:
        raise InstallError("Invalid kit checksums")
    actual_files = {str(p.relative_to(kit)) for p in kit.rglob("*") if p.is_file() and p != manifest}
    if actual_files != set(expected):
        raise InstallError("Kit file inventory differs from SHA256.json")
    for name, digest in expected.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or not isinstance(digest, str):
            raise InstallError("Invalid checksum path")
        item = kit / relative
        no_links(item)
        if hashlib.sha256(item.read_bytes()).hexdigest() != digest:
            raise InstallError("Kit integrity check failed")


def helper_python(home, requested=None):
    candidates = [requested] if requested else [sys.executable, shutil.which("python3"),
        str(home / ".cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")]
    for candidate in dict.fromkeys(p for p in candidates if p):
        try:
            command([candidate, "-c", "import sys, yaml; assert sys.version_info >= (3, 9)"], timeout=5)
            return candidate
        except (InstallError, OSError, subprocess.TimeoutExpired):
            continue
    raise InstallError("Codex validation needs Python 3.9+ with PyYAML. Supply --python /path/to/python3; nothing was installed.")


def atomic_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".phonebridge-market-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(kit, home, skill, python, codex, dry_run=False, run=command, process_check=None):
    kit, home, skill = Path(kit).absolute(), Path(home).absolute(), Path(skill).absolute()
    app_source, plugin_source = kit / "Mac/PhoneBridge.app", kit / "plugin/phonebridge"
    app_target, plugin_target = home / "Applications/PhoneBridge.app", home / "plugins/phonebridge"
    marketplace = home / ".agents/plugins/marketplace.json"
    for source in (app_source, plugin_source):
        validate_tree(source)
    verify_checksums(kit)
    for target in (app_target, plugin_target, marketplace):
        no_links(target)
    with (app_source / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != "cn.andy.phonebridge":
            raise InstallError("Unexpected application identity")
    if json.loads((plugin_source / ".codex-plugin/plugin.json").read_text()).get("name") != "phonebridge":
        raise InstallError("Unexpected plugin identity")
    if app_target.exists():
        existing_info = app_target / "Contents/Info.plist"
        if not existing_info.is_file() or plistlib.loads(existing_info.read_bytes()).get("CFBundleIdentifier") != "cn.andy.phonebridge":
            raise InstallError("Existing application target has another identity; no files changed")
    if plugin_target.exists():
        existing_manifest = plugin_target / ".codex-plugin/plugin.json"
        if not existing_manifest.is_file() or json.loads(existing_manifest.read_bytes()).get("name") != "phonebridge":
            raise InstallError("Existing plugin target has another identity; no files changed")
    for name in ("create_basic_plugin.py", "read_marketplace_name.py", "update_plugin_cachebuster.py", "validate_plugin.py"):
        if not (skill / "scripts" / name).is_file():
            raise InstallError("Install the Codex plugin-creator skill before using this installer")
    original_market, existing_entry = validate_marketplace(marketplace, plugin_target)
    env = dict(os.environ, HOME=str(home))
    def helper(name, *arguments):
        return run([python, str(skill / "scripts" / name)] + list(arguments), env=env)
    name = helper("read_marketplace_name.py", "--marketplace-path", str(marketplace)) if original_market is not None else "personal"
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise InstallError("Invalid marketplace name")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_source)])
    plan = {"app": str(app_target), "plugin": str(plugin_target), "marketplace": name,
            "marketplaceAction": "reuse existing entry" if existing_entry else "official scaffold in staging",
            "backUpExistingFiles": True, "copiesPrivateSettings": False,
            "startsPhoneOrVoice": False, "dryRun": dry_run}
    if dry_run:
        return plan
    if process_check is None:
        process_check = lambda: subprocess.run(["/usr/bin/pgrep", "-x", "PhoneBridge"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode
    running = process_check()
    if running != 1:
        raise InstallError("Quit PhoneBridge normally before updating; its idle state cannot be assumed")
    home.mkdir(parents=True, exist_ok=True)
    lock_path = home / ".phonebridge-install.lock"
    no_links(lock_path)
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(lock_fd)
        raise InstallError("Another PhoneBridge installation is already in progress")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    replaced, backups = [], {}
    published_market = None
    registration_started = False
    try:
        with tempfile.TemporaryDirectory(prefix=".phonebridge-install-", dir=home) as temporary:
            stage = Path(temporary)
            staged_app, staged_plugin = stage / "PhoneBridge.app", stage / "plugin/phonebridge"
            shutil.copytree(app_source, staged_app)
            shutil.copytree(plugin_source, staged_plugin)
            staged_market = stage / "marketplace.json"
            if not existing_entry:
                if original_market is not None:
                    staged_market.write_bytes(original_market)
                # Scaffold never touches the customized manifest or uses --force.
                # Only its official generated marketplace bytes are published later.
                helper("create_basic_plugin.py", "phonebridge", "--path", str(stage / "scaffold"),
                       "--marketplace-path", str(staged_market), "--with-marketplace")
                generated = staged_market.read_bytes()
                if helper("read_marketplace_name.py", "--marketplace-path", str(staged_market)) != name:
                    raise InstallError("Scaffold marketplace identity changed")
            if file_bytes(marketplace) != original_market:
                raise InstallError("Marketplace changed during preparation; retry")
            if process_check() != 1:
                raise InstallError("PhoneBridge started during preparation; quit it normally before updating")
            def replace(source, target):
                no_links(target)
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    backup = target.with_name(target.name + ".backup-" + stamp)
                    target.rename(backup)
                    backups[target] = backup
                replaced.append(target)
                source.rename(target)
            replace(staged_app, app_target)
            # Immutable server.py may remain after rollback; it contains code only,
            # never keys or preferences, and may already be used by an older cache.
            run([python, str(staged_plugin / "scripts/install-runtime.py"), "--app-path", str(app_target)], env=env)
            helper("update_plugin_cachebuster.py", str(staged_plugin))
            old_manifest = plugin_target / ".codex-plugin/plugin.json"
            if old_manifest.is_file():
                old = json.loads(old_manifest.read_text()).get("version")
                new = json.loads((staged_plugin / ".codex-plugin/plugin.json").read_text()).get("version")
                if old == new:
                    time.sleep(1.05)  # Official cachebuster has one-second resolution.
                    helper("update_plugin_cachebuster.py", str(staged_plugin))
            helper("validate_plugin.py", str(staged_plugin))
            replace(staged_plugin, plugin_target)
            if file_bytes(marketplace) != original_market:
                raise InstallError("Marketplace changed before registration; local files will be restored")
            if not existing_entry:
                if original_market is not None:
                    market_backup = marketplace.with_name(marketplace.name + ".backup-" + stamp)
                    atomic_bytes(market_backup, original_market)
                    backups[marketplace] = market_backup
                atomic_bytes(marketplace, generated)
                published_market = generated
            registration_started = True
            run([codex, "plugin", "add", "phonebridge@" + name, "--json"], timeout=90, env=env)
        return dict(plan, installed=True, codexCommandSucceeded=True,
                    backups={str(k): str(v) for k, v in backups.items()},
                    note="Open a new Codex task. Actual phone/audio and another-Mac installation still require verification.")
    except BaseException as error:
        if registration_started:
            retry = shlex.join([codex, "plugin", "add", "phonebridge@" + name, "--json"])
            raise InstallError("Codex registration did not complete. New local files and backups remain; "
                               "Codex cache state is unverified. Retry: " + retry + "; backups: " +
                               json.dumps({str(k): str(v) for k, v in backups.items()})) from error
        rollback_errors = []
        for target in reversed(replaced):
            try:
                no_links(target)
                if target.exists():
                    shutil.rmtree(target)
                if target in backups:
                    backups[target].rename(target)
            except (OSError, InstallError):
                rollback_errors.append(str(target))
        if published_market is not None:
            try:
                if file_bytes(marketplace) != published_market:
                    raise OSError("concurrent marketplace change")
                if original_market is None:
                    marketplace.unlink()
                else:
                    atomic_bytes(marketplace, original_market)
            except OSError:
                rollback_errors.append(str(marketplace))
        message = "Local replacements restored" if not rollback_errors else "Rollback incomplete: " + ", ".join(rollback_errors)
        raise InstallError(message + ". No successful Codex registration. " +
                           "An immutable code-only MCP runtime may remain. " +
                           (str(error) if isinstance(error, InstallError) else "Installation step failed.")) from error
    finally:
        os.close(lock_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kit", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--python", help="Python 3.9+ with PyYAML for the official Codex validator")
    args = parser.parse_args()
    codex = shutil.which("codex")
    if not codex:
        raise InstallError("Install Codex with its CLI first; nothing was installed")
    home = Path.home()
    result = install(args.kit, home, home / ".codex/skills/.system/plugin-creator",
                     helper_python(home, args.python), codex, args.dry_run)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (InstallError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
