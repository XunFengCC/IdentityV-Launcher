#!/bin/zsh
# Stage an exact, already obtained upstream idv-login release as package input.
# This script is deliberately offline and never reads an installed component.
set -euo pipefail

ROOT="${0:A:h:h}"
MANIFEST="$ROOT/idvLoginComponent.json"
CACHE_ROOT="$ROOT/idvLoginComponent/releaseCache"

if (( $# != 1 )) || [[ "$1" != /* ]]; then
  print -u2 -- "用法：stageIdvLoginReleasePayload.command /绝对路径/idv-login-v6.3.0-stable-mac"
  exit 64
fi
SOURCE="$1"
[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || { print -u2 -- "来源必须是普通文件：$SOURCE"; exit 1; }

read_manifest() {
  /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null
}
VERSION="$(read_manifest version)"
ASSET_NAME="$(read_manifest assetName)"
EXPECTED_SIZE="$(read_manifest byteSize)"
EXPECTED_SHA="$(read_manifest sha256)"
[[ "$VERSION" == "6.3.0" && "$ASSET_NAME" == "idv-login-v6.3.0-stable-mac" ]] || {
  print -u2 -- "只允许当前固定的 IDV Login 6.3.0 payload。"; exit 1;
}
[[ "$EXPECTED_SIZE" == <-> && "$EXPECTED_SHA" != *[^0-9a-f]* && ${#EXPECTED_SHA} -eq 64 ]] || {
  print -u2 -- "组件清单的大小或 SHA-256 格式无效。"; exit 1;
}
ACTUAL_SIZE="$(/usr/bin/stat -f '%z' "$SOURCE")"
ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$SOURCE" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_SIZE" == "$EXPECTED_SIZE" ]] || { print -u2 -- "组件大小不匹配。"; exit 1; }
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || { print -u2 -- "组件 SHA-256 不匹配。"; exit 1; }
/usr/bin/file "$SOURCE" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64' || {
  print -u2 -- "组件不是原生 arm64 Mach-O。"; exit 1;
}

TARGET_DIR="$CACHE_ROOT/$VERSION"
TARGET="$TARGET_DIR/$ASSET_NAME"
/bin/mkdir -p "$TARGET_DIR"
/bin/chmod 700 "$CACHE_ROOT" "$TARGET_DIR"
/bin/cp -p "$SOURCE" "$TARGET"
/bin/chmod 600 "$TARGET"
[[ "$(/usr/bin/stat -f '%z' "$TARGET")" == "$EXPECTED_SIZE" ]]
[[ "$(/usr/bin/shasum -a 256 "$TARGET" | /usr/bin/awk '{print $1}')" == "$EXPECTED_SHA" ]]
/usr/bin/file "$TARGET" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64'
print -- "已暂存固定 IDV Login $VERSION payload：$TARGET"
