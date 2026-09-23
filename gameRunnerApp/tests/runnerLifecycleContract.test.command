#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
main_runner="$root/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
agtk_runner="$root/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
forwarder="${root:h}/wineKeyboardPatch/IdentityVCommandGraveForwarder.m"
launcher_source="$root/IdentityVLauncher.c"
product_manager="${root:h}/productManager/IdentityVProductManager.swift"

cmp -s "$main_runner" "$agtk_runner"
for app in "$root/IdentityV-Mac.app" "$root/IdentityV-AGTK.app"; do
  [[ "$(/usr/bin/plutil -extract LSUIElement raw -o - "$app/Contents/Info.plist")" == "true" ]]
done

! /usr/bin/grep -Fq '/usr/bin/osascript' "$main_runner"
! /usr/bin/grep -Fq 'System Events' "$main_runner"
! /usr/bin/grep -Fq 'IDENTITYV_INITIAL_WINDOW_SIZE' "$main_runner"
/usr/bin/python3 - "$main_runner" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
assert source.count('"$APP_CONTENTS/Resources/IdentityVGameActivator" --pid') == 1
assert source.index('"$APP_CONTENTS/Resources/IdentityVGameActivator" --pid') > source.index('  wine_pid="$LAUNCHED_WINE_PID"')
assert source.index('"$APP_CONTENTS/Resources/IdentityVGameActivator" --pid') < source.index('  while /bin/kill -0 "$wine_pid"')
assert '--expected-executable "$WINE_BIN" --timeout 90' in source
PY
/usr/bin/grep -Fq 'runner_path, "--product"' "$launcher_source"
! /usr/bin/grep -Fq 'runner_path, "--run"' "$launcher_source"
/usr/bin/grep -Fq 'process.executableURL = try embeddedGameRunnerExecutable(runner: app)' "$product_manager"
! /usr/bin/grep -Fq 'process.executableURL = URL(fileURLWithPath: "/usr/bin/open")' "$product_manager"
/usr/bin/grep -Fq "/usr/bin/printf 'schema=1\\nproduct=%s\\nrunner_pid=%s\\nwine_pid=%s\\nwindows_root=%s\\n'" "$main_runner"
! /usr/bin/grep -Fq 'print -r -- "schema=1\nproduct=' "$main_runner"

/usr/bin/grep -Fq 'event.keyCode != kVK_ANSI_Grave' "$forwarder"
! /usr/bin/grep -Fq 'kVK_ANSI_1' "$forwarder"
! /usr/bin/grep -Fq 'kVK_ANSI_C' "$forwarder"
/usr/bin/grep -Fq 'NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp;' "$forwarder"
/usr/bin/grep -Fq '[window sendEvent:event]' "$forwarder"
! /usr/bin/grep -Fq 'NSSelectorFromString(@"postKeyEvent:")' "$forwarder"

print -r -- "runner lifecycle and Command shortcut contract self-test passed"
