#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE_ROOT="$PROJECT_ROOT/inputLatencyProbe"
OUTPUT="$SOURCE_ROOT/IdentityVInputLatencyProbe"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

/bin/rm -f "$OUTPUT"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  -O \
  -g \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  "$SOURCE_ROOT/Models.swift" \
  "$SOURCE_ROOT/LatencyAnalyzer.swift" \
  "$SOURCE_ROOT/Capture.swift" \
  "$SOURCE_ROOT/main.swift" \
  -o "$OUTPUT" \
  -framework Cocoa \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework CoreVideo

/usr/bin/codesign --force --sign - \
  --identifier com.fengyin.identityv.development.input-latency-probe \
  "$OUTPUT"
/bin/chmod +x "$OUTPUT"

print -r -- "构建完成：$OUTPUT"
