#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
BUILD_DIR="$PROJECT_ROOT/wineAudioInterposer/build"
typeset -A RESOURCES=(
  [load-only]=IdentityVCoreAudio-load-only.dylib
  [passthrough]=IdentityVCoreAudio-passthrough.dylib
  [caller]=IdentityVCoreAudio-caller.dylib
  [filter]=IdentityVCoreAudio-filter.dylib
  [passthrough-handle]=IdentityVCoreAudio-passthrough-handle.dylib
  [rebinder]=IdentityVCoreAudio-rebinder.dylib
  [rebinder-filter]=IdentityVCoreAudio-rebinder-filter.dylib
  [rebinder-default-alias]=IdentityVCoreAudio-rebinder-default-alias.dylib
)
TARGETS=(
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app"
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"
)

for app in "${TARGETS[@]}"; do
  [[ -d "$app/Contents/Resources" ]] || { print -u2 -- "缺少项目候选 App：$app"; exit 1; }
  for stage resource_name in ${(kv)RESOURCES}; do
    source="$BUILD_DIR/IdentityVCoreAudio-${stage}.dylib"
    [[ -f "$source" ]] || { print -u2 -- "缺少 $stage 构建产物；请先运行 wineAudioInterposer/buildAndVerify.command。"; exit 1; }
    /usr/bin/file "$source" | /usr/bin/grep -q 'x86_64' || { print -u2 -- "$stage 候选不是 x86_64 dylib。"; exit 1; }
    destination="$app/Contents/Resources/$resource_name"
    /bin/cp "$source" "$destination"
    /bin/chmod 755 "$destination"
    /usr/bin/codesign --force --sign - "$destination"
  done
  /usr/bin/codesign --force --deep --sign - "$app"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
done

"$PROJECT_ROOT/runtimeManifest/auditMachODeploymentTargets.command" \
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/Resources"/IdentityVCoreAudio-*.dylib \
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/Resources"/IdentityVCoreAudio-*.dylib

print -r -- "八个音频候选已暂存到项目 App；未修改 /Applications 中的活动安装，默认 stage=off。"
