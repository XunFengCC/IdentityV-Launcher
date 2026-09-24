#!/usr/bin/env python3
"""Bind a release App to its source revision and actual runtime selection.

The public rc.1 contained an emoji repair candidate in its catalog while the
product manager still selected r1. Packaging now checks the selected engine,
installed runtime hashes, App resources, and source revision together.
"""

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True
    )
    if result.returncode:
        fail(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def app_identity(app: Path) -> dict:
    contents = app / "Contents"
    resources = contents / "Resources"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    manifest = json.loads((resources / "runtime-manifest.json").read_text())
    catalog = json.loads((resources / "runtime-catalog.json").read_text())
    if manifest.get("schemaVersion") != 1 or catalog.get("schemaVersion") != 1:
        fail("unsupported runtime manifest or catalog schema")
    defaults = [
        (engine_id, engine)
        for engine_id, engine in catalog.get("engines", {}).items()
        if engine.get("candidateSelection", {}).get("productDefault") is True
    ]
    if len(defaults) != 1:
        fail("runtime catalog must have exactly one product default")
    engine_id, engine = defaults[0]
    selection = engine["candidateSelection"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", engine_id):
        fail("invalid product runtime engine ID")
    if selection.get("runtimeVersion") != manifest.get("version"):
        fail("product engine and bootstrap runtime versions disagree")
    if engine.get("launchProfile") != "codeweavers-wine-release-dxmt":
        fail("product runtime launch profile is unsupported")
    verified = {
        item.get("relativePath"): item.get("sha256")
        for item in engine.get("verificationFiles", {}).values()
    }
    for item in manifest.get("finalVerificationFiles", []):
        if verified.get(item.get("relativePath")) != item.get("sha256"):
            fail(f"runtime hash differs from product catalog: {item.get('relativePath')}")
    runner_catalog = contents / "Helpers/IdentityVGameRunner.app/Contents/Resources/runtime-catalog.json"
    if sha256(runner_catalog) != sha256(resources / "runtime-catalog.json"):
        fail("embedded game runner and product manager have different runtime catalogs")
    font = engine.get("fontConfiguration")
    if font:
        filename = font.get("cjkFilename", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.ttf", filename):
            fail("invalid product font filename")
        bundled_font = contents / "Helpers/IdentityVGameRunner.app/Contents/Resources/Fonts" / filename
        if sha256(bundled_font) != font.get("cjkSha256"):
            fail("selected product font differs from the catalog")
        for notice in ("Noto-CJK-OFL-1.1.txt", "Noto-Emoji-OFL-1.1.txt"):
            if not (resources / "ThirdParty" / notice).is_file():
                fail(f"selected product font lacks notice: {notice}")
    version = info.get("IdentityVReleaseVersion")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        fail("invalid App release version")
    return {
        "schemaVersion": 1,
        "releaseVersion": version,
        "buildNumber": str(info.get("CFBundleVersion", "")),
        "productEngineId": engine_id,
        "runtimeVersion": manifest["version"],
        "infoSha256": sha256(contents / "Info.plist"),
        "runtimeManifestSha256": sha256(resources / "runtime-manifest.json"),
        "runtimeCatalogSha256": sha256(resources / "runtime-catalog.json"),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("stamp", "verify"))
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--source-commit")
    parser.add_argument("--source-clean", choices=("true", "false"))
    args = parser.parse_args()
    repo, app = args.repo.resolve(), args.app.resolve()
    provenance_file = app / "Contents/Resources/build-provenance.json"
    identity = app_identity(app)
    if args.action == "stamp":
        if not args.source_commit or not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
            fail("stamp requires a Git source commit")
        if args.source_clean is None:
            fail("stamp requires the pre-build source clean state")
        identity["sourceCommit"] = args.source_commit
        identity["sourceClean"] = args.source_clean == "true"
        provenance_file.write_text(
            json.dumps(identity, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        return

    saved = json.loads(provenance_file.read_text())
    for key, value in identity.items():
        if saved.get(key) != value:
            fail(f"built App provenance differs from its payload: {key}")
    if saved.get("sourceClean") is not True:
        fail("built App came from a dirty source tree; rebuild from a committed revision")
    if saved.get("sourceCommit") != git(repo, "rev-parse", "HEAD"):
        fail("built App source commit differs from the current checkout")
    # Building re-signs tracked runner templates and can dirty the checkout.
    # The recorded *pre-build* clean state binds the App to HEAD; requiring a
    # clean tree here would reject an otherwise valid build of that revision.
    for relative, bundled in (
        ("playerLauncherApp/Info.plist", app / "Contents/Info.plist"),
        ("runtimeBootstrap/runtime-manifest.json", app / "Contents/Resources/runtime-manifest.json"),
        ("runtimeManifest/runtime-catalog.json", app / "Contents/Resources/runtime-catalog.json"),
    ):
        if sha256(repo / relative) != sha256(bundled):
            fail(f"built App contains an older or different source resource: {relative}")
    tag = "v" + identity["releaseVersion"]
    if subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "-q", "--verify", "refs/tags/" + tag],
        capture_output=True,
    ).returncode == 0:
        fail(f"release version {identity['releaseVersion']} already has a Git tag; bump the version")
    print(
        f"Release input verified: {identity['releaseVersion']} / "
        f"{identity['productEngineId']} / {saved['sourceCommit'][:12]}"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"Release identity check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
