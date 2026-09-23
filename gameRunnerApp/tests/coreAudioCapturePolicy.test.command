#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
CATALOG="$PROJECT_ROOT/runtimeManifest/runtime-catalog.json"

[[ -x "$RUNNER" && -x "$AGTK_RUNNER" && -r "$CATALOG" ]]
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"

# The first case establishes a default before user settings load; the second
# one is the authoritative, post-settings policy gate.  Execute that exact
# runner fragment in a local shell so stale launcher.env values cannot silently
# become an alternative implementation of the contract.
typeset -i policy_case_count=0
policy_case_count="$(/usr/bin/grep -Fxc 'case "$CORE_AUDIO_CAPTURE_POLICY" in' "$RUNNER" || true)"
[[ "$policy_case_count" == 2 ]] || {
  print -u2 -- "expected separate default and post-settings CoreAudio policy gates"
  exit 1
}
policy_source="$(/usr/bin/awk '
  /^case "\$CORE_AUDIO_CAPTURE_POLICY" in$/ { count++; capture = (count == 2) }
  capture { print }
  capture && /^esac$/ { exit }
' "$RUNNER")"
[[ -n "$policy_source" ]] || { print -u2 -- "cannot locate post-settings CoreAudio policy gate"; exit 1; }

resolve_stage() {
  local policy="$1" stage="$2" legacy="$3"
  CORE_AUDIO_CAPTURE_POLICY="$policy"
  IDENTITYV_AUDIO_INTERPOSER_STAGE="$stage"
  IDENTITYV_DEFAULT_INPUT_ONLY="$legacy"
  eval "$policy_source"
  print -r -- "$IDENTITYV_AUDIO_INTERPOSER_STAGE"
}

# Existing Wine 11 runtimes have no source-level device filter.  Their policy
# must win over both an old explicit `off` and the discontinued legacy switch.
[[ "$(resolve_stage rebinder-filter-required off 1)" == rebinder-filter ]]
[[ "$(resolve_stage rebinder-filter-required filter 0)" == rebinder-filter ]]
/usr/bin/plutil -extract 'engines.wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1.capabilities.coreAudioCapturePolicy' raw -o - "$CATALOG" | /usr/bin/grep -qx 'rebinder-filter-required'

# r4's source-level default-input implementation must never receive an old
# rebinder/filter dylib in addition, even if either legacy setting persisted.
[[ "$(resolve_stage runtime-default-input-only rebinder-filter 0)" == off ]]
[[ "$(resolve_stage runtime-default-input-only filter 1)" == off ]]

# The fallback policy intentionally preserves maintenance overrides, including
# the old flag's off -> filter translation.
[[ "$(resolve_stage unmanaged rebinder 1)" == rebinder ]]
[[ "$(resolve_stage unmanaged off 1)" == filter ]]
[[ "$(resolve_stage unmanaged rebinder-filter 0)" == rebinder-filter ]]

print -r -- "CoreAudio capture policy self-test passed"
