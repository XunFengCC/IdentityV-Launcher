#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE="$PROJECT_ROOT/gameActivator/main.swift"
BUILD_DIR="$PROJECT_ROOT/gameActivator/build"
OUTPUT="$BUILD_DIR/IdentityVGameActivator"

/bin/mkdir -p "$BUILD_DIR"
/usr/bin/xcrun --sdk macosx swiftc \
  -target arm64-apple-macos14.0 \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  "$SOURCE" \
  -o "$OUTPUT"

/usr/bin/codesign --force --sign - \
  --identifier com.xunfeng.identityv.game-activator \
  "$OUTPUT"
/usr/bin/codesign --verify --strict --verbose=2 "$OUTPUT"
/usr/bin/lipo -verify_arch arm64 "$OUTPUT"
/usr/bin/otool -l "$OUTPUT" | /usr/bin/grep -A3 -q 'minos 14.0'
LC_ALL=C /usr/bin/grep -q 'print("result=' "$SOURCE"
"$OUTPUT" --self-test | /usr/bin/grep -qx 'result=self_test_ok elapsed_ms=[0-9][0-9]*'

typeset -a TARGET_APPS
TARGET_APPS=(
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app"
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"
)

for app in "${TARGET_APPS[@]}"; do
  [[ -d "$app/Contents/Resources" ]] || continue
  /bin/cp -f "$OUTPUT" "$app/Contents/Resources/IdentityVGameActivator"
  /usr/bin/codesign --force --deep --sign - "$app"
  /usr/bin/codesign --verify --strict --verbose=2 "$app"
done

print -r -- "构建完成：$OUTPUT"
print -r -- "已更新项目内两个 launcher App；未启动 Wine、游戏或系统授权流程。"
