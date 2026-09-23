#!/bin/zsh
# Static-only contract for the self-built r4 catalog entry. It neither stages,
# installs, selects, launches, nor mutates a runtime or prefix.
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
CATALOG="$PROJECT_ROOT/runtimeManifest/runtime-catalog.json"
R4_MANIFEST="${IDENTITYV_R4_MANIFEST:-}"
R4_ID='wine11-codeweavers-26_1-dxmt-0_80-selfbuilt-gnutls-macos15-r4'
LKG_ID='wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1'

[[ -r "$CATALOG" ]]

# The r4 manifest is a separately supplied maintainer candidate. When it is
# absent the build must still be able to package the product, so the
# catalog-only contract still runs and the missing half is reported loudly
# instead of failing the whole launcher build.  Rationale: r4 is an explicitly
# non-default maintainer candidate, the build neither stages nor launches it,
# and silently skipping the check is what this branch is designed to prevent.
if [[ -z "$R4_MANIFEST" || ! -r "$R4_MANIFEST" ]]; then
  print -u2 -- "WARNING: self-built r4 manifest is unavailable (set IDENTITYV_R4_MANIFEST to verify its files)"
  print -u2 -- "WARNING: catalog structure is verified; runtime file digests are NOT verified in this build."
  /usr/bin/python3 - "$CATALOG" "$R4_ID" "$LKG_ID" <<'PY'
import json
import pathlib
import sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text())
r4_id, lkg_id = sys.argv[2:]
assert catalog["schemaVersion"] == 1
r4 = catalog["engines"][r4_id]
lkg = catalog["engines"][lkg_id]
assert r4["launchProfile"] == "codeweavers-wine-release-dxmt"
assert r4["candidateSelection"] == {"channel": "maintainer-selfbuilt-candidate", "productDefault": False, "fallbackEngineId": lkg_id, "requiresIsolatedPrefix": True, "activation": "explicit-maintainer-selection-only"}
assert r4["candidateSelection"]["productDefault"] is False
assert lkg["launchProfile"] == "codeweavers-wine-release-dxmt"
assert r4["capabilities"] == {"coreAudioCapturePolicy": "runtime-default-input-only", "mediaRuntimePolicy": "without-gstreamer", "d3dcompiler47Policy": "verified-game-native-dynamic-only"}
assert r4["executablePaths"] == {"wine": "bin/wine", "wineserver": "bin/wineserver"}
assert r4["verificationFiles"]["moltenVK"] == {"status": "not-bundled-by-r4"}
assert r4["verificationFiles"]["gstreamer"] == {"status": "without-gstreamer"}
assert r4["licenseNotice"]["status"] == "candidate-corresponding-sources-and-notices-required-before-distribution"
print("self-built r4 catalog structure contract passed (runtime digests not verified: manifest volume absent)")
PY
  exit 0
fi

/usr/bin/python3 - "$CATALOG" "$R4_MANIFEST" "$R4_ID" "$LKG_ID" <<'PY'
import hashlib
import json
import pathlib
import sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text())
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
r4_id, lkg_id = sys.argv[3:]
assert catalog["schemaVersion"] == 1
r4 = catalog["engines"][r4_id]
lkg = catalog["engines"][lkg_id]
assert manifest["engineId"] == r4_id
assert r4["launchProfile"] == "codeweavers-wine-release-dxmt"
assert r4["candidateSelection"] == {"channel": "maintainer-selfbuilt-candidate", "productDefault": False, "fallbackEngineId": lkg_id, "requiresIsolatedPrefix": True, "activation": "explicit-maintainer-selection-only"}
assert lkg["launchProfile"] == "codeweavers-wine-release-dxmt"
assert r4["capabilities"] == {"coreAudioCapturePolicy": "runtime-default-input-only", "mediaRuntimePolicy": "without-gstreamer", "d3dcompiler47Policy": "verified-game-native-dynamic-only"}
assert r4["executablePaths"] == {"wine": "bin/wine", "wineserver": "bin/wineserver"}
expected = {
    "wine": ("bin/wine", "efa838eb370c3c1cdd4c035e1663785e35c69e79fbe8f087dcae15e2c8cb69d1"),
    "wineserver": ("bin/wineserver", "79271d5f6e1fa1f9ed4cfccc6f03433aa0f2e332d5f6bc0f3a35fa1c9665e4d8"),
    "dxmt": ("lib/dxmt/x86_64-unix/winemetal.so", "49249e3a578157a14a5baa53940d619037dab52ab26e6ad5b8a6c46f39d46f2a"),
    "winemac": ("lib/wine/x86_64-unix/winemac.so", "987e0ca0535eaf30a49d64a2e5b7836b51f0aa4f2cc5028112c50fe38545bb90"),
    "gnutls": ("lib/gnutls/lib/libgnutls.30.dylib", "99e69fb4fd06ba6f40b8331780c510a1cafb91e4bcc4f29a9941b6882dd612ed"),
    "gmp": ("lib/gnutls/lib/libgmp.10.dylib", "9395c87c5744fff83852d45b7d3300c1ee136a51f5700476df416b4a920cc557"),
    "nettle": ("lib/gnutls/lib/libnettle.8.dylib", "bc8039bfabd9acee23c7d47371f949513fa661109c040aae793d639e52ebf463"),
    "hogweed": ("lib/gnutls/lib/libhogweed.6.dylib", "5da6fbe02237ba91109455a5b680a840fd65b2d6d2196ff8e3665392cc95d709"),
}
for key, (path, digest) in expected.items():
    assert r4["verificationFiles"][key] == {"relativePath": path, "sha256": digest}
    runtime_path = pathlib.Path(sys.argv[2]).parent.parent / path
    assert runtime_path.is_file()
    assert hashlib.sha256(runtime_path.read_bytes()).hexdigest() == digest
assert r4["verificationFiles"]["moltenVK"] == {"status": "not-bundled-by-r4"}
assert r4["verificationFiles"]["gstreamer"] == {"status": "without-gstreamer"}
for key, manifest_path in {"wine": "bin/wine", "wineserver": "bin/wineserver", "dxmt": "lib/dxmt/x86_64-unix/winemetal.so", "winemac": "lib/wine/x86_64-unix/winemac.so"}.items():
    assert manifest["keyFilesSHA256"][manifest_path]["sha256"] == r4["verificationFiles"][key]["sha256"]
assert r4["licenseNotice"]["status"] == "candidate-corresponding-sources-and-notices-required-before-distribution"
print("self-built r4 runtime catalog contract passed")
PY
