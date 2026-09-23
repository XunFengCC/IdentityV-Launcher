#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
tmp="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$tmp"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macos14.0 \
  "$root/playerLauncherApp/Sources/ToolboxModels.swift" \
  "$root/diagnostics/FeedbackDestinationSelfTest.swift" \
  -o "$tmp/FeedbackDestinationSelfTest"
"$tmp/FeedbackDestinationSelfTest"
