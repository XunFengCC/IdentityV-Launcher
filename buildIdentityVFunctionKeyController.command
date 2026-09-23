#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h}"
BUILD_ROOT="$PROJECT_ROOT/functionKeyController/build"
/bin/mkdir -p "$BUILD_ROOT"
OUTPUT="$BUILD_ROOT/IdentityVFunctionKeyController"
/usr/bin/xcrun swiftc -O -parse-as-library -swift-version 5 -warnings-as-errors \
  -target arm64-apple-macos14.0 -framework AppKit -framework IOKit \
  "$PROJECT_ROOT/functionKeyController/IdentityVFunctionKeyController.swift" -o "$OUTPUT"
"$OUTPUT" --self-test
"$OUTPUT" --status
# Exercise the real Swift/IOKit lifetime path without modifying mappings;
# fake-backend fixtures cannot catch a released event-system client.
"$OUTPUT" --mapping-status
/usr/bin/codesign --force --sign - --identifier com.xunfeng.identityv.function-keys "$OUTPUT"
/usr/bin/codesign --verify --strict "$OUTPUT"
"$PROJECT_ROOT/runtimeManifest/auditMachODeploymentTargets.command" "$OUTPUT"
print -- "Built $OUTPUT"
