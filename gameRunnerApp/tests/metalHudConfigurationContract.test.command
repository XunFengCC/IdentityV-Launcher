#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-metal-hud.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"
! /usr/bin/grep -Fq 'IDENTITYV_METAL_HUD' "$RUNNER"
! /usr/bin/grep -Fq 'launchctl setenv' "$RUNNER"
/usr/bin/grep -Fq 'unset MTL_HUD_ENABLED MTL_HUD_LOG_ENABLED' "$RUNNER"
/usr/bin/grep -Fq 'MTL_HUD_ENCODER_TIMING_ENABLED' "$RUNNER"
/usr/bin/grep -Fq 'Metal HUD enabled for final dwrg.exe child only' "$RUNNER"
/usr/bin/grep -Fq 'export "${hud_environment[@]}"' "$RUNNER"
/usr/bin/grep -Fq 'exec "$WINE_BIN" "C:\\Games\\${WINDOWS_GAME_ROOT}\\dwrg.exe"' "$RUNNER"
! /usr/bin/grep -Fq '/usr/bin/env "${hud_environment[@]}" "$WINE_BIN"' "$RUNNER"
/usr/bin/grep -Fq 'MTL_HUD_DISABLE_MENU_BAR=1' "$RUNNER"
/usr/bin/grep -Fq 'MTL_HUD_SHOW_METRICS_RANGE=1' "$RUNNER"
/usr/bin/grep -Fq 'MTL_HUD_ELEMENTS=device,layersize,memory,fps,frameinterval,gputime,presentdelay,frameintervalgraph,fpsgraph' "$RUNNER"
! /usr/bin/grep -Fq 'export MTL_HUD_' "$RUNNER"

function_source="$(
  /usr/bin/sed -n '/^metal_hud_file_is_safe() {/,/^}/p' "$RUNNER"
  /usr/bin/sed -n '/^load_metal_hud_configuration() {/,/^}/p' "$RUNNER"
)"
[[ -n "$function_source" ]] || { print -u2 -- 'cannot extract Metal HUD configuration functions'; exit 1; }
eval "$function_source"

CONFIG_DIR="$TEST_ROOT/IdentityVOnMac"
MAINTENANCE_DIR="$CONFIG_DIR/Maintenance"
METAL_HUD_CONFIG_FILE="$MAINTENANCE_DIR/metal-hud.env"
/bin/mkdir -p "$MAINTENANCE_DIR"
/bin/chmod 700 "$CONFIG_DIR" "$MAINTENANCE_DIR"

write_config() {
  /bin/rm -f "$METAL_HUD_CONFIG_FILE"
  print -r -- "$1" >| "$METAL_HUD_CONFIG_FILE"
  /bin/chmod 600 "$METAL_HUD_CONFIG_FILE"
}
load_and_expect() {
  METAL_HUD_ENABLED=9
  METAL_HUD_CONFIG_REASON=''
  load_metal_hud_configuration
  [[ "$METAL_HUD_ENABLED" == "$1" ]]
}

# Missing, explicitly disabled and enabled all obey the same strict config.
load_and_expect 0
write_config $'schema=1\nenabled=0'
load_and_expect 0
write_config $'schema=1\nenabled=1'
load_and_expect 1
/bin/chmod 400 "$METAL_HUD_CONFIG_FILE"
load_and_expect 1
/bin/chmod 600 "$METAL_HUD_CONFIG_FILE"

# Any extra/malformed line, link or group/other permission bit fails closed.
write_config $'schema=1\nenabled=1\nextra=unsafe'
load_and_expect 0
/bin/rm -f "$METAL_HUD_CONFIG_FILE"
/bin/ln -s "$TEST_ROOT/not-a-config" "$METAL_HUD_CONFIG_FILE"
load_and_expect 0
/bin/rm -f "$METAL_HUD_CONFIG_FILE"
write_config $'schema=1\nenabled=1'
/bin/chmod 077 "$METAL_HUD_CONFIG_FILE"
load_and_expect 0
/bin/chmod 606 "$METAL_HUD_CONFIG_FILE"
load_and_expect 0
/bin/chmod 644 "$METAL_HUD_CONFIG_FILE"
load_and_expect 0
/bin/chmod 600 "$METAL_HUD_CONFIG_FILE"
/bin/chmod 710 "$MAINTENANCE_DIR"
load_and_expect 0
/bin/chmod 700 "$MAINTENANCE_DIR"
/bin/chmod 755 "$MAINTENANCE_DIR"
load_and_expect 0

# The legacy controls really write the only accepted configuration and never
# call launchctl. Use a temporary HOME so this does not alter the user's HUD.
SCRIPT_HOME="$TEST_ROOT/script-home"
ENABLE_SCRIPT="$PROJECT_ROOT/enableMetalHudForNextLaunch.command"
DISABLE_SCRIPT="$PROJECT_ROOT/disableMetalHud.command"
! /usr/bin/grep -Fq 'launchctl' "$ENABLE_SCRIPT"
! /usr/bin/grep -Fq 'launchctl' "$DISABLE_SCRIPT"
/usr/bin/env HOME="$SCRIPT_HOME" IDV_TOOLBOX_NONINTERACTIVE=1 /bin/zsh "$ENABLE_SCRIPT" >/dev/null
SCRIPT_CONFIG="$SCRIPT_HOME/Library/Application Support/IdentityVOnMac/Maintenance/metal-hud.env"
[[ "$(/bin/cat "$SCRIPT_CONFIG")" == $'schema=1\nenabled=1' ]]
[[ "$(/usr/bin/stat -f '%Lp' "${SCRIPT_CONFIG:h}")" == 700 && "$(/usr/bin/stat -f '%Lp' "$SCRIPT_CONFIG")" == 600 ]]
/usr/bin/env HOME="$SCRIPT_HOME" IDV_TOOLBOX_NONINTERACTIVE=1 /bin/zsh "$DISABLE_SCRIPT" >/dev/null
[[ "$(/bin/cat "$SCRIPT_CONFIG")" == $'schema=1\nenabled=0' ]]

# Run the product launch function against a controllable Wine stub: direct
# launch gets the private HUD, virtual desktop gets none, and auxiliary
# wineserver work is scrubbed even if a hostile parent supplied HUD variables.
launch_source="$(/usr/bin/sed -n '/^launch_game_once() {/,/^}/p' "$RUNNER")"
clear_source="$(/usr/bin/sed -n '/^clear_metal_hud_environment() {/,/^}/p' "$RUNNER")"
stop_source="$(/usr/bin/sed -n '/^stop_prefix_processes() {/,/^}/p' "$RUNNER")"
eval "$launch_source"
eval "$clear_source"
eval "$stop_source"
MOCK_WINE="$TEST_ROOT/mock-wine"
MOCK_GAME_LOG="$TEST_ROOT/mock-game.log"
MOCK_AUX_LOG="$TEST_ROOT/mock-aux.log"
/usr/bin/clang -arch arm64 -mmacosx-version-min=14.0 -Wall -Wextra -Werror \
  "$PROJECT_ROOT/testFixtures/IdentityVEnvironmentDumper.c" -o "$MOCK_WINE"
/usr/bin/file "$MOCK_WINE" | /usr/bin/grep -Fq 'Mach-O 64-bit executable arm64'
MOCK_WINESERVER="$TEST_ROOT/mock-wineserver"
{
  print -r -- '#!/bin/zsh'
  print -r -- 'print -r -- "enabled=${MTL_HUD_ENABLED-unset} args=$*" >> "$MOCK_AUX_LOG"'
} >| "$MOCK_WINESERVER"
/bin/chmod 700 "$MOCK_WINESERVER"
export IDENTITYV_ENV_DUMPER_OUTPUT="$MOCK_GAME_LOG" MOCK_AUX_LOG
COMMAND_GRAVE_FORWARDER=""
AUDIO_INTERPOSER=""
IDV_LOGIN_START_HELPER="$TEST_ROOT/no-helper"
LOGIN_DNS_COMPAT="$TEST_ROOT/no-dns"
INPUT_TRACE_ONCE_MARKER="$TEST_ROOT/no-input-trace"
WINE_BIN="$MOCK_WINE"
PRODUCT=mainland
WINDOWS_GAME_ROOT=IdentityV
GAME_LAUNCH_ARGUMENTS=(--start_from_launcher=1)
WINEDEBUG='-all'
export DYLD_FALLBACK_LIBRARY_PATH='test-wine-fallback'
METAL_HUD_ENABLED=1
IDENTITYV_USE_VIRTUAL_DESKTOP=0
IDENTITYV_DESKTOP_NAME=IdentityV
IDENTITYV_DESKTOP_SIZE=1920x1080
LOG_FILE="$TEST_ROOT/product.log"
RUN_SESSION_FILE="$TEST_ROOT/direct-session"
launch_game_once
wait "$LAUNCHED_WINE_PID"
/usr/bin/grep -Fxq -- 'enabled=1 menu=1 log=0 fallback=test-wine-fallback args=C:\Games\IdentityV\dwrg.exe --start_from_launcher=1' "$MOCK_GAME_LOG"
: >| "$MOCK_GAME_LOG"
IDENTITYV_USE_VIRTUAL_DESKTOP=1
RUN_SESSION_FILE="$TEST_ROOT/virtual-session"
launch_game_once
wait "$LAUNCHED_WINE_PID"
/usr/bin/grep -Fxq -- 'enabled=unset menu=unset log=unset fallback=test-wine-fallback args=explorer /desktop=IdentityV,1920x1080 C:\Games\IdentityV\dwrg.exe --start_from_launcher=1' "$MOCK_GAME_LOG"
: >| "$MOCK_GAME_LOG"
IDENTITYV_USE_VIRTUAL_DESKTOP=0
METAL_HUD_ENABLED=0
RUN_SESSION_FILE="$TEST_ROOT/disabled-session"
launch_game_once
wait "$LAUNCHED_WINE_PID"
/usr/bin/grep -Fxq -- 'enabled=unset menu=unset log=unset fallback=test-wine-fallback args=C:\Games\IdentityV\dwrg.exe --start_from_launcher=1' "$MOCK_GAME_LOG"
PREFIX="$TEST_ROOT/prefix"
WINEPREFIX="$PREFIX"
WINESERVER_BIN="$MOCK_WINESERVER"
/bin/mkdir -p "$PREFIX"
export MTL_HUD_ENABLED=poison
stop_prefix_processes
/usr/bin/grep -Fqx -- 'enabled=unset args=-k' "$MOCK_AUX_LOG"
/usr/bin/grep -Fqx -- 'enabled=unset args=-w' "$MOCK_AUX_LOG"

print -r -- 'Metal HUD configuration contract self-test passed'
