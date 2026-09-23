#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-game-root-binding.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

[[ -x "$RUNNER" && -x "$AGTK_RUNNER" ]]
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"

function_source="$(/usr/bin/awk '
  /^game_root_binding_is_valid\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$RUNNER")"
[[ -n "$function_source" ]] || { print -u2 -- "cannot locate game_root_binding_is_valid"; exit 1; }
eval "$function_source"

physical_root="$TEST_ROOT/physical"
alias_root="$TEST_ROOT/alias"
game_dir="$physical_root/game"
managed_link="$TEST_ROOT/prefix/drive_c/Games/IdentityV"
/bin/mkdir -p "$game_dir" "${managed_link:h}" "$TEST_ROOT/foreign"
/bin/ln -s "$physical_root" "$alias_root"
/bin/ln -s "$alias_root/game" "$managed_link"

# The binding check is based on device/inode identity rather than a textual
# `realpath` spelling.  This same predicate accepts the startup Data volume's
# `/Users` and `/System/Volumes/Data/Users` aliases in the live RC.
game_root_binding_is_valid "$game_dir" "$managed_link"

/bin/rm "$managed_link"
/bin/ln -s "$TEST_ROOT/foreign" "$managed_link"
if game_root_binding_is_valid "$game_dir" "$managed_link"; then
  print -u2 -- "foreign game-root binding was accepted"
  exit 1
fi

/bin/rm "$managed_link"
/bin/mkdir -p "$managed_link"
if game_root_binding_is_valid "$game_dir" "$managed_link"; then
  print -u2 -- "real directory was accepted in place of the managed link"
  exit 1
fi

print -r -- "game-root APFS alias binding self-test passed"
