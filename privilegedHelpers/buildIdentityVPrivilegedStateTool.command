#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/privilegedHelpers/IdentityVPrivilegedStateTool.swift"
OUTPUT="$ROOT/.build/identityv-state-tool"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

/bin/mkdir -p "${OUTPUT:h}"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  "$SOURCE" \
  -o "$OUTPUT"
/bin/chmod 755 "$OUTPUT"
/usr/bin/codesign --force --sign - --identifier com.xunfeng.identityv.privileged-state "$OUTPUT"
"$OUTPUT" --self-test
/usr/bin/file "$OUTPUT" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64'
"$ROOT/runtimeManifest/auditMachODeploymentTargets.command" "$OUTPUT"
/usr/bin/printf '构建完成：%s\n' "$OUTPUT"
