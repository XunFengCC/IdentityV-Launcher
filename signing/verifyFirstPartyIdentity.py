#!/usr/bin/env python3
"""Verify shipped first-party bundle and Mach-O IDs after the identity change.

This is a read-only candidate check. Compatibility labels, the historical AGTK
template and the four hash-locked runtime patch payloads are intentionally not
new first-party identities.
"""

import argparse
import plistlib
from pathlib import Path
import subprocess

PREFIX = "com.fengyin.identityv"


def bundle_id(app: Path) -> str:
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)["CFBundleIdentifier"]


def signed_id(path: Path) -> str:
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "-v", str(path)],
        check=True, capture_output=True, text=True,
    )
    return next(
        (line.partition("=")[2] for line in result.stderr.splitlines()
         if line.startswith("Identifier=")),
        "",
    )


def entitlements(app: Path) -> dict:
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)],
        check=True, capture_output=True,
    )
    return plistlib.loads(result.stdout)


def verify_launcher(app: Path) -> None:
    runner = app / "Contents/Helpers/IdentityVGameRunner.app"
    expected_bundles = {app: f"{PREFIX}.launcher", runner: f"{PREFIX}.runner"}
    for bundle, expected in expected_bundles.items():
        actual = bundle_id(bundle)
        assert actual == expected, f"{bundle}: plist ID {actual} != {expected}"
        assert signed_id(bundle) == expected, f"{bundle}: signed ID differs"
        assert entitlements(bundle).get("com.apple.security.device.audio-input") is True, (
            f"{bundle}: missing microphone entitlement"
        )
    assert entitlements(app).get("com.apple.security.automation.apple-events") is True

    resources = "Contents/Resources/"
    runner_resources = "Contents/Helpers/IdentityVGameRunner.app/Contents/Resources/"
    expected = {
        "Contents/MacOS/IdentityVLauncher": f"{PREFIX}.launcher",
        "Contents/MacOS/IdentityVHangPrompt": f"{PREFIX}.launcher.hang-prompt",
        "Contents/Helpers/IdentityVMicrophoneAuthorization": f"{PREFIX}.launcher.microphone-authorization",
        resources + "IdentityVProductManager": f"{PREFIX}.launcher.product-manager",
        resources + "IdentityVDownloadSupervisor": f"{PREFIX}.launcher.download-supervisor",
        resources + "IdentityVManifestPlanner": f"{PREFIX}.launcher.manifest-planner",
        resources + "IdentityVDownloaderCoreBootstrap": f"{PREFIX}.launcher.downloader-core-bootstrap",
        resources + "IdentityVGlobalAdapter": f"{PREFIX}.launcher.global-adapter",
        resources + "IdentityVRuntimeBootstrap": f"{PREFIX}.launcher.runtime-bootstrap",
        resources + "IdentityVDiagnosticExporter": f"{PREFIX}.launcher.diagnostic-exporter",
        resources + "IdentityVIdvLoginDownloader": f"{PREFIX}.launcher.idv-login-downloader",
        resources + "InstallerPayload/identityv-state-tool": f"{PREFIX}.installer.privileged-state",
        runner_resources + "IdentityVFunctionKeyController": f"{PREFIX}.runner.function-keys",
        runner_resources + "IdentityVGameActivator": f"{PREFIX}.runner.game-activator",
        runner_resources + "IdentityVLoginDNSCompat.dylib": f"{PREFIX}.runner.login-dns-compat",
        runner_resources + "IdentityVMouseAccelerationController": f"{PREFIX}.runner.mouse-acceleration-controller",
        runner_resources + "IdentityVCommandGraveForwarder.dylib": f"{PREFIX}.runner.command-grave-forwarder",
    }
    for stage in (
        "load-only", "passthrough", "caller", "filter", "passthrough-handle",
        "rebinder", "rebinder-filter", "rebinder-default-alias",
    ):
        expected[runner_resources + f"IdentityVCoreAudio-{stage}.dylib"] = (
            f"{PREFIX}.runner.audio.{stage}"
        )
    verify_macho_ids(app, expected)


def verify_toolbox(app: Path) -> None:
    expected = f"{PREFIX}.toolbox"
    assert bundle_id(app) == expected and signed_id(app) == expected
    assert entitlements(app).get("com.apple.security.automation.apple-events") is True
    verify_macho_ids(app, {
        "Contents/MacOS/IdentityVMonitor": expected,
        "Contents/MacOS/IdentityVOverlayDisplay": f"{PREFIX}.toolbox.display",
        "Contents/Resources/idv-dense-metrics": f"{PREFIX}.toolbox.sampler",
    })


def verify_macho_ids(app: Path, expected: dict[str, str]) -> None:
    for relative, identifier in expected.items():
        path = app / relative
        assert path.is_file(), f"missing signed input: {path}"
        actual = signed_id(path)
        assert actual == identifier, f"{relative}: signed ID {actual} != {identifier}"
    print(f"First-party identity contract passed: {len(expected)} Mach-O files")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("launcher", "toolbox"))
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    if args.kind == "launcher":
        verify_launcher(args.app)
    else:
        verify_toolbox(args.app)


if __name__ == "__main__":
    main()
