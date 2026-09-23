#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
tmp="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$tmp"' EXIT
sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -sdk "$sdk" \
  "$root/diagnostics/IdentityVDiagnosticExporter.swift" \
  -o "$tmp/IdentityVDiagnosticExporter"
"$tmp/IdentityVDiagnosticExporter" --self-test
/usr/bin/file "$tmp/IdentityVDiagnosticExporter" | /usr/bin/grep -q 'arm64'
