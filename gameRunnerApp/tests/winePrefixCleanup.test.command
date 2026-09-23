#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
RESTART_SCRIPT="$PROJECT_ROOT/restartIdentityVGame.command"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-wine-prefix-cleanup.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

[[ -x "$RUNNER" && -x "$AGTK_RUNNER" ]]
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"

# The runner must never use a broad process matcher to tidy Wine.  Its one
# cleanup authority is the selected runtime's wineserver while WINEPREFIX is
# exactly the prefix it resolved during preflight.
/usr/bin/grep -Fq '"${WINEPREFIX:-}" != "$PREFIX"' "$RUNNER"
/usr/bin/grep -Fq '"$WINESERVER_BIN" -k' "$RUNNER"
/usr/bin/grep -Fq '"$WINESERVER_BIN" -w' "$RUNNER"
/usr/bin/grep -Fq "trap 'handle_launcher_signal TERM 143' TERM" "$RUNNER"
/usr/bin/grep -Fq 'leave the active Wine session untouched' "$RUNNER"
/usr/bin/grep -Fq 'GAME_LAUNCH_ARGUMENTS=()' "$RUNNER"
/usr/bin/grep -Fq 'GAME_LAUNCH_ARGUMENTS=(--start_from_launcher=1 --is_multi_start)' "$RUNNER"
/usr/bin/grep -Fq '.launcher-session-${PRODUCT}.env' "$RUNNER"
/usr/bin/grep -Fq 'pgrep -u "$(id -u)" -f "C:\\\\Games\\\\${WINDOWS_GAME_ROOT}\\\\dwrg[.]exe"' "$RUNNER"
typeset -a dll_override_exports
dll_override_exports=("${(@f)$(/usr/bin/grep '^[[:space:]]*export WINEDLLOVERRIDES=' "$RUNNER")}")
[[ ${#dll_override_exports} -eq 2 ]]
for override_export in $dll_override_exports; do
  if [[ "$override_export" != *'mscoree,mshtml='* ]]; then
    print -u2 -- "every game launch profile must suppress Wine Mono/Gecko installers"
    exit 1
  fi
done
if [[ "${dll_override_exports[1]}" != *'winegstreamer='* ]]; then
  print -u2 -- "CodeWeavers LKG profile must disable its unclosed winegstreamer path"
  exit 1
fi
if [[ "${dll_override_exports[2]}" == *'winegstreamer='* ]]; then
  print -u2 -- "Sikarugir profile must not inherit the LKG-only winegstreamer override"
  exit 1
fi
if /usr/bin/grep -Fq 'dwrg[.]exe.*--start_from_launcher=1' "$RUNNER"; then
  print -u2 -- "runner must not use mainland-only launch arguments for global process identity"
  exit 1
fi
if /usr/bin/grep -Eq '(pkill|killall|pgrep).*wine' "$RUNNER"; then
  print -u2 -- "runner cleanup must not select Wine processes by a broad pattern"
  exit 1
fi

# The restart action derives a runner from each game's parent chain; it must
# not enumerate every launcher by name and terminate another product's session.
/usr/bin/grep -Fq 'runner_pids_for_games()' "$RESTART_SCRIPT"
/usr/bin/grep -Fq 'runner_pids_for_games "$initial_game_pids"' "$RESTART_SCRIPT"
if /usr/bin/grep -Fq 'matching_pids "$RUNNER_PATTERN"' "$RESTART_SCRIPT"; then
  print -u2 -- "restart action must not select all launcher runners"
  exit 1
fi

clear_source="$(/usr/bin/awk '
  /^clear_metal_hud_environment\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$RUNNER")"
stop_source="$(/usr/bin/awk '
  /^stop_prefix_processes\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$RUNNER")"
function_source="$clear_source"$'\n'"$stop_source"
[[ -n "$function_source" ]] || { print -u2 -- "cannot locate stop_prefix_processes"; exit 1; }
eval "$function_source"

export PREFIX="$TEST_ROOT/selected-prefix"
export WINEPREFIX="$PREFIX"
export LOG_FILE="$TEST_ROOT/runner.log"
/bin/mkdir -p "$PREFIX"

MOCK_WINESERVER="$PROJECT_ROOT/gameRunnerApp/tests/mockWineserver.command"
[[ -x "$MOCK_WINESERVER" ]]
export WINESERVER_BIN="$MOCK_WINESERVER"
export MOCK_WINESERVER_LOG="$TEST_ROOT/wineserver.log"
export MOCK_WINESERVER_MARKER="$TEST_ROOT/prefix-services-live"
/usr/bin/touch "$MOCK_WINESERVER_MARKER"

stop_prefix_processes
[[ ! -e "$MOCK_WINESERVER_MARKER" ]]
/usr/bin/grep -Fx -- "-k prefix=$PREFIX" "$MOCK_WINESERVER_LOG"
/usr/bin/grep -Fx -- "-w prefix=$PREFIX" "$MOCK_WINESERVER_LOG"

# A mismatch must fail closed without invoking the selected wineserver, even
# though it is executable. This models a corrupted or inherited environment
# and proves the cleanup cannot cross into IDV Login/another server prefix.
: >| "$MOCK_WINESERVER_LOG"
export WINEPREFIX="$TEST_ROOT/other-prefix"
if stop_prefix_processes; then
  print -u2 -- "mismatched WINEPREFIX unexpectedly permitted cleanup"
  exit 1
fi
[[ ! -s "$MOCK_WINESERVER_LOG" ]]
/usr/bin/grep -Fq 'skip Wine prefix cleanup' "$LOG_FILE"

print -r -- "Wine prefix cleanup self-test passed"
