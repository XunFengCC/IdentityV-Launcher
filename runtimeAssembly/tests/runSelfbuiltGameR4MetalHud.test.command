#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$root/runSelfbuiltGameR4.command"
fixture="$(mktemp -d /tmp/identityv-r4-hud.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT

function_source="$(
  sed -n '/^clear_metal_hud_environment() {/,/^}/p' "$runner"
  sed -n '/^metal_hud_file_is_safe() {/,/^}/p' "$runner"
  sed -n '/^load_metal_hud_configuration() {/,/^}/p' "$runner"
  sed -n '/^run_bounded() {/,/^}/p' "$runner"
  sed -n '/^build_metal_hud_environment() {/,/^}/p' "$runner"
)"
[[ -n "$function_source" ]] || { printf '%s\n' 'cannot extract r4 HUD functions' >&2; exit 1; }
eval "$function_source"

IDENTITYV_CONFIG_DIR="$fixture/IdentityVOnMac"
IDENTITYV_MAINTENANCE_DIR="$IDENTITYV_CONFIG_DIR/Maintenance"
METAL_HUD_CONFIG_FILE="$IDENTITYV_MAINTENANCE_DIR/metal-hud.env"
mkdir -p "$IDENTITYV_MAINTENANCE_DIR"
chmod 700 "$IDENTITYV_CONFIG_DIR" "$IDENTITYV_MAINTENANCE_DIR"
printf 'schema=1\nenabled=1\n' >"$METAL_HUD_CONFIG_FILE"
chmod 600 "$METAL_HUD_CONFIG_FILE"
metal_hud_enabled=0
metal_hud_reason=''
load_metal_hud_configuration
[[ "$metal_hud_enabled" == 1 ]]
build_metal_hud_environment
mock="$fixture/mock-final-child"
record="$fixture/final-child.env"
/usr/bin/clang -arch arm64 -mmacosx-version-min=14.0 -Wall -Wextra -Werror \
  "$root/../testFixtures/IdentityVEnvironmentDumper.c" -o "$mock"
/usr/bin/file "$mock" | /usr/bin/grep -Fq 'Mach-O 64-bit executable arm64'
export IDENTITYV_ENV_DUMPER_OUTPUT="$record"
export DYLD_FALLBACK_LIBRARY_PATH='test-r4-fallback'
(
  export "${hud_environment[@]}"
  exec "$mock"
)
grep -Fxq -- 'enabled=1 menu=1 log=0 fallback=test-r4-fallback args=' "$record"

# Disabled final-child path keeps Wine's library fallback but exports no HUD.
metal_hud_enabled=0
build_metal_hud_environment
(
  if ((${#hud_environment[@]})); then export "${hud_environment[@]}"; fi
  exec "$mock"
)
grep -Fxq -- 'enabled=unset menu=unset log=unset fallback=test-r4-fallback args=' "$record"

# A helper inherits no Metal HUD even if a caller put one in its environment.
helper="$fixture/mock-helper"
helper_record="$fixture/helper.env"
printf '%s\n' '#!/bin/bash' 'printf "enabled=%s\n" "${MTL_HUD_ENABLED-unset}" > "$R4_HUD_HELPER_RECORD"' >"$helper"
chmod 700 "$helper"
export R4_HUD_HELPER_RECORD="$helper_record"
log="$fixture/runner.log"
export MTL_HUD_ENABLED=poison
run_bounded 2 "$helper"
grep -Fxq -- 'enabled=unset' "$helper_record"

# The production r4 launch path must use the execing shell child, never env.
grep -Fq 'export "${hud_environment[@]}"' "$runner"
grep -Fq 'exec "$wine" '\''C:\Games\IdentityV\dwrg.exe'\''' "$runner"
! grep -Fq '/usr/bin/env "${hud_environment[@]}" "$wine"' "$runner"

chmod 606 "$METAL_HUD_CONFIG_FILE"
load_metal_hud_configuration
[[ "$metal_hud_enabled" == 0 ]]
printf '%s\n' 'r4 Metal HUD parser and injection contract passed'
