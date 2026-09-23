#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE="$PROJECT_ROOT/wineKeyboardPatch/IdentityVCommandGraveForwarder.m"
POLICY_SOURCE="$PROJECT_ROOT/wineKeyboardPatch/IdentityVAudioKeyPolicy.c"
POLICY_TEST_SOURCE="$PROJECT_ROOT/wineKeyboardPatch/IdentityVAudioKeyPolicyTest.c"
BUILD_DIR="$PROJECT_ROOT/wineKeyboardPatch/build"
OUTPUT="$BUILD_DIR/IdentityVCommandGraveForwarder.dylib"
POLICY_TEST_OUTPUT="$BUILD_DIR/IdentityVAudioKeyPolicyTest"
INSTALL_ACTIVE=0

if (( $# > 1 )); then
  print -u2 -- "用法：${0:t} [--install-active]"
  exit 2
fi
if (( $# == 1 )); then
  [[ "$1" == "--install-active" ]] || { print -u2 -- "未知参数：$1"; exit 2; }
  INSTALL_ACTIVE=1
fi

/bin/mkdir -p "$BUILD_DIR"
/usr/bin/clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  "$POLICY_SOURCE" \
  "$POLICY_TEST_SOURCE" \
  -o "$POLICY_TEST_OUTPUT"
"$POLICY_TEST_OUTPUT"

/usr/bin/xcrun --sdk macosx clang \
  -arch x86_64 \
  -fobjc-arc \
  -fblocks \
  -dynamiclib \
  -Wl,-install_name,@rpath/IdentityVCommandGraveForwarder.dylib \
  -mmacosx-version-min=14.0 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -framework AppKit \
  -framework Carbon \
  -framework CoreAudio \
  "$SOURCE" \
  "$POLICY_SOURCE" \
  -o "$OUTPUT"

/usr/bin/codesign --force --sign - \
  --identifier com.xunfeng.identityv.command-grave-forwarder \
  "$OUTPUT"
/usr/bin/codesign --verify --strict --verbose=2 "$OUTPUT"
/usr/bin/otool -D "$OUTPUT" | /usr/bin/tail -n 1 | /usr/bin/grep -qx '@rpath/IdentityVCommandGraveForwarder.dylib'
/usr/bin/nm -u "$OUTPUT" | /usr/bin/grep -E '_AudioObject(Get|Set)PropertyData|_AudioObjectIsPropertySettable|_AudioObjectHasProperty' >/dev/null
/usr/bin/strings "$OUTPUT" | /usr/bin/grep -F 'audio key action skipped' >/dev/null

typeset -a TARGET_APPS
TARGET_APPS=(
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app" \
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"
)
(( INSTALL_ACTIVE )) && TARGET_APPS+=("/Applications/第五人格 Mac.app")

for app in "${TARGET_APPS[@]}"; do
  [[ -d "$app/Contents/Resources" ]] || continue
  /bin/cp -f "$OUTPUT" "$app/Contents/Resources/IdentityVCommandGraveForwarder.dylib"
  /usr/bin/codesign --force --deep --sign - "$app"
done

print -r -- "构建完成：$OUTPUT"
(( INSTALL_ACTIVE )) || print -- "仅更新项目内 App；未修改 /Applications 中的活动安装。"
