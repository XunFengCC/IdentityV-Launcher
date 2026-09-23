#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE="$PROJECT_ROOT/mouseAccelerationController/IdentityVMouseAccelerationController.m"
BUILD_DIR="$PROJECT_ROOT/mouseAccelerationController/build"
OUTPUT="$BUILD_DIR/IdentityVMouseAccelerationController"
INSTALL_ACTIVE=0

case "${1:-}" in
  '') ;;
  --install-active) INSTALL_ACTIVE=1 ;;
  *) print -u2 -- "usage: $0 [--install-active]"; exit 64 ;;
esac

/bin/mkdir -p "$BUILD_DIR"
/usr/bin/clang -fobjc-arc -O2 -Wall -Wextra -Werror \
  -mmacosx-version-min=14.0 \
  -framework Cocoa \
  -framework IOKit \
  "$SOURCE" \
  -o "$OUTPUT"

/usr/bin/codesign --force --sign - \
  --identifier com.xunfeng.identityv.mouse-acceleration-controller \
  "$OUTPUT"
/bin/chmod +x "$OUTPUT"

status_json="$("$OUTPUT" --status)"
[[ "$status_json" == *'"configured":false'* && "$status_json" == *'"found":false'* ]] || {
  print -u2 -- "generic no-device self-test failed"
  exit 1
}
status_json_again="$("$OUTPUT" --status)"
[[ "$status_json" == "$status_json_again" ]] || {
  print -u2 -- "generic no-device status is not stable"
  exit 1
}

targets=(
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app"
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"
)
if (( INSTALL_ACTIVE )); then
  targets+=("/Applications/第五人格 Mac.app")
fi

for app in "${targets[@]}"; do
  [[ -d "$app/Contents/Resources" ]] || continue
  /bin/cp -f "$OUTPUT" "$app/Contents/Resources/IdentityVMouseAccelerationController"
  /bin/chmod +x "$app/Contents/Resources/IdentityVMouseAccelerationController"
  /usr/bin/codesign --force --deep --sign - "$app"
done

print -r -- "构建完成：$OUTPUT"
if (( ! INSTALL_ACTIVE )); then
  print -r -- "仅更新项目内 App；未修改 /Applications 中的活动安装。"
fi
