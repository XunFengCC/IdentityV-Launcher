#!/usr/bin/env python3
"""Isolate idv-login hotfix state when switching component versions.

The macOS build stores Python overlay modules outside the bundled executable.
Upstream 6.2.3 activates every pending/applied record without checking that the
record belongs to the running version.  Reusing a 6.1 overlay can therefore
replace a 6.2 module with an incompatible implementation.

This helper preserves all non-hotfix configuration, creates recoverable
backups, archives the old overlay, and clears only the version-scoped hotfix
keys so the target component can probe its own updates.
"""

from __future__ import annotations

import argparse
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import tempfile
import time
from typing import Optional


HOTFIX_KEYS = (
    "hotfix_probed",
    "hotfix_records",
    "hotfix_pending_validate",
    "hotfix_applied",
    "hotfix_skipped",
)


def _unique_path(base: Path) -> Path:
    if not base.exists():
        return base
    index = 1
    while True:
        candidate = base.with_name(f"{base.name}-{index}")
        if not candidate.exists():
            return candidate
        index += 1


def _chown_tree(path: Path, uid: int, gid: int) -> None:
    os.chown(path, uid, gid, follow_symlinks=False)
    if not path.is_dir():
        return
    for root, directories, files in os.walk(path, followlinks=False):
        root_path = Path(root)
        for name in directories + files:
            os.chown(root_path / name, uid, gid, follow_symlinks=False)


def _atomic_write_json(path: Path, data: dict, original_stat: os.stat_result) -> None:
    payload = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".config.hotfix-migration-", dir=str(path.parent)
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        shutil.copystat(path, temporary_path, follow_symlinks=False)
        os.chmod(temporary_path, stat.S_IMODE(original_stat.st_mode))
        os.chown(temporary_path, original_stat.st_uid, original_stat.st_gid)
        os.replace(temporary_path, path)
        try:
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def migrate(
    work_dir: Path,
    from_version: str,
    to_version: str,
    backup_uid: int,
    backup_gid: int,
    timestamp: Optional[str] = None,
) -> dict:
    result = {
        "migrated": False,
        "from_version": from_version,
        "to_version": to_version,
        "config_backup": "",
        "overlay_backup": "",
        "cleared_keys": [],
    }
    if not from_version or from_version == to_version:
        return result

    config_path = work_dir / "config.json"
    overlay_path = work_dir / "hotfix_overlay"
    backup_dir = work_dir / "componentMigrationBackups"
    for path, label in (
        (work_dir, "work directory"),
        (config_path, "config"),
        (overlay_path, "hotfix overlay"),
        (backup_dir, "migration backup directory"),
    ):
        if path.is_symlink():
            raise ValueError(f"{label} must not be a symbolic link")
    config_data: Optional[dict] = None
    config_stat: Optional[os.stat_result] = None

    if config_path.exists():
        config_stat = config_path.stat()
        with config_path.open("r", encoding="utf-8") as stream:
            loaded = json.load(stream)
        if not isinstance(loaded, dict):
            raise ValueError("idv-login config must contain a JSON object")
        config_data = loaded

    cleared_keys = [key for key in HOTFIX_KEYS if config_data is not None and key in config_data]
    if config_data is None and not overlay_path.exists() and not cleared_keys:
        return result

    stamp = timestamp or time.strftime("%Y%m%d-%H%M%S")
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    os.chown(backup_dir, backup_uid, backup_gid)

    if config_data is not None and config_stat is not None:
        config_backup = _unique_path(backup_dir / f"config-before-{to_version}-{stamp}.json")
        shutil.copy2(config_path, config_backup)
        os.chmod(config_backup, 0o600)
        os.chown(config_backup, backup_uid, backup_gid)
        result["config_backup"] = str(config_backup)

    if overlay_path.exists():
        overlay_backup = _unique_path(
            backup_dir / f"hotfix-overlay-{from_version}-before-{to_version}-{stamp}"
        )
        os.replace(overlay_path, overlay_backup)
        _chown_tree(overlay_backup, backup_uid, backup_gid)
        result["overlay_backup"] = str(overlay_backup)

    if config_data is not None and config_stat is not None and cleared_keys:
        for key in HOTFIX_KEYS:
            config_data.pop(key, None)
        _atomic_write_json(config_path, config_data, config_stat)

    result["migrated"] = True
    result["cleared_keys"] = cleared_keys
    return result


def _run_self_test() -> None:
    uid = os.getuid()
    gid = os.getgid()
    with tempfile.TemporaryDirectory(prefix="idv-login-hotfix-migration-test-") as temporary:
        work_dir = Path(temporary)
        config = {
            "account_records": [{"keep": "unchanged"}],
            "game_path": "/Applications/IdentityV.app",
            "hotfix_probed": True,
            "hotfix_records": {"v6.1.0-mac|cloudRes@old": {"status": "applied"}},
            "hotfix_pending_validate": ["old"],
            "hotfix_applied": ["old"],
            "hotfix_skipped": ["old-skipped"],
        }
        (work_dir / "config.json").write_text(
            json.dumps(config, ensure_ascii=False), encoding="utf-8"
        )
        overlay = work_dir / "hotfix_overlay"
        overlay.mkdir()
        (overlay / "cloudRes.py").write_text("OLD = True\n", encoding="utf-8")

        result = migrate(work_dir, "6.1.0", "6.2.3", uid, gid, "TEST")
        migrated = json.loads((work_dir / "config.json").read_text(encoding="utf-8"))
        assert migrated["account_records"] == config["account_records"]
        assert migrated["game_path"] == config["game_path"]
        assert not any(key in migrated for key in HOTFIX_KEYS)
        assert Path(result["config_backup"]).is_file()
        assert Path(result["overlay_backup"], "cloudRes.py").is_file()
        assert not overlay.exists()

        no_op = migrate(work_dir, "6.2.3", "6.2.3", uid, gid, "TEST2")
        assert no_op["migrated"] is False

    with tempfile.TemporaryDirectory(prefix="idv-login-hotfix-symlink-test-") as temporary:
        work_dir = Path(temporary) / "idv-login"
        work_dir.mkdir()
        external_overlay = Path(temporary) / "outside"
        external_overlay.mkdir()
        (external_overlay / "do-not-touch.py").write_text("KEEP = True\n", encoding="utf-8")
        (work_dir / "hotfix_overlay").symlink_to(external_overlay, target_is_directory=True)
        try:
            migrate(work_dir, "6.1.0", "6.2.3", uid, gid, "TEST3")
        except ValueError as error:
            assert "symbolic link" in str(error)
        else:
            raise AssertionError("symlinked overlay must be rejected")
        assert (external_overlay / "do-not-touch.py").is_file()
    print("idv-login hotfix migration self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-dir")
    parser.add_argument("--from-version")
    parser.add_argument("--to-version")
    parser.add_argument("--backup-owner")
    parser.add_argument("--backup-group", default="staff")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        _run_self_test()
        return
    for name in ("work_dir", "from_version", "to_version", "backup_owner"):
        if not getattr(args, name):
            parser.error(f"--{name.replace('_', '-')} is required")

    work_dir = Path(args.work_dir)
    if not work_dir.is_absolute() or work_dir.name != "idv-login":
        raise SystemExit("work directory must be an absolute idv-login directory")
    uid = pwd.getpwnam(args.backup_owner).pw_uid
    gid = grp.getgrnam(args.backup_group).gr_gid
    expected_work_dir = (
        Path("/Users") / args.backup_owner / "Library/Application Support/idv-login"
    )
    if work_dir != expected_work_dir:
        raise SystemExit(f"work directory must be exactly {expected_work_dir}")
    result = migrate(work_dir, args.from_version, args.to_version, uid, gid)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
