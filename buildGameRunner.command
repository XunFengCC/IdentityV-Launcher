#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE="$PROJECT_ROOT/gameRunnerApp/IdentityVLauncher.c"
RUNTIME_CATALOG="$PROJECT_ROOT/runtimeManifest/runtime-catalog.json"
BUILD_DIR="$PROJECT_ROOT/.build"
OUTPUT="$BUILD_DIR/launchIdentityV"
TARGETS=(
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app"
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"
)

# 代码签名身份：原因、优先级与边界见 signing/lib/signIdentityV.sh。
source "$PROJECT_ROOT/signing/lib/signIdentityV.sh"
identityv_resolve_identity

mkdir -p "$BUILD_DIR"
/usr/bin/clang -x objective-c -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -Wall -Wextra -Werror \
  -framework AppKit "$SOURCE" -o "$OUTPUT"

for app in "${TARGETS[@]}"; do
  target="$app/Contents/MacOS/launchIdentityV"
  [[ -d "$app" ]] || { print -u2 "Missing app bundle: $app"; exit 1; }
  [[ -r "$RUNTIME_CATALOG" ]] || { print -u2 "Missing runtime catalog: $RUNTIME_CATALOG"; exit 1; }
  /usr/bin/install -m 755 "$OUTPUT" "$target"
  /usr/bin/install -m 444 "$RUNTIME_CATALOG" "$app/Contents/Resources/runtime-catalog.json"
  # 由内到外签整个 runner bundle（内含 DNS/音频/按键等注入 dylib）。
  identityv_sign_bundle_tree "$app"
  identityv_verify_bundle_tree "$app"
  /usr/bin/file "$target" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64'
done

"$PROJECT_ROOT/runtimeManifest/auditMachODeploymentTargets.command" "$OUTPUT" \
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityV" \
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityV"

print "Built and installed the arm64 launcher into:"
print -l -- "${TARGETS[@]}"
