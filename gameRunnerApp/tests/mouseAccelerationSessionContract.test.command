#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
controller="$root:h/mouseAccelerationController/IdentityVMouseAccelerationController.m"
runner="$root/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
agtk_runner="$root/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"

cmp -s "$runner" "$agtk_runner"

# A session owns an exact selected pointing device and records a private,
# structured original value, including an absent property, before it changes it.
/usr/bin/grep -Fq 'usagePage.integerValue == 1' "$controller"
/usr/bin/grep -Fq 'usage.integerValue == 2' "$controller"
/usr/bin/grep -Fq '@"linearAcceleration": originalValue ?: [NSNull null]' "$controller"
/usr/bin/grep -Fq 'mkstemp(templatePath)' "$controller"
/usr/bin/grep -Fq 'fchmod(descriptor, S_IRUSR | S_IWUSR)' "$controller"
/usr/bin/grep -Fq 'chmod(stateFile.fileSystemRepresentation, S_IRUSR | S_IWUSR)' "$controller"
/usr/bin/grep -Fq '@"--begin-session"' "$controller"
/usr/bin/grep -Fq '@"--end-session"' "$controller"
/usr/bin/grep -Fq 'stateMatchesLinearAcceleration(target.service, @1)' "$controller"
/usr/bin/grep -Fq 'cannot restore the selected pointing device' "$controller"
! /usr/bin/grep -Fq '@"--watch"' "$controller"

# The runner starts the session before Wine and restores through EXIT cleanup;
# it never starts a foreground-application watcher.
/usr/bin/grep -Fq 'MOUSE_ACCELERATION_STATE_FILE="$CONFIG_DIR/mouse-acceleration-${PRODUCT}.session.json"' "$runner"
/usr/bin/grep -Fq 'begin_mouse_acceleration_session' "$runner"
/usr/bin/grep -Fq 'end_mouse_acceleration_session' "$runner"
/usr/bin/grep -Fq 'cleanup_launcher' "$runner"
! /usr/bin/grep -Fq -- '--watch' "$runner"
! /usr/bin/grep -Fq 'MOUSE_ACCELERATION_CONTROLLER_PID=' "$runner"

begin_call_line="$(/usr/bin/grep -n '^begin_mouse_acceleration_session$' "$runner" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
launch_call_line="$(/usr/bin/grep -n '^  launch_game_once$' "$runner" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
end_call_line="$(/usr/bin/grep -n '^  end_mouse_acceleration_session$' "$runner" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
prefix_cleanup_line="$(/usr/bin/grep -n '^  stop_prefix_processes$' "$runner" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ "$begin_call_line" == <-> && "$launch_call_line" == <-> && begin_call_line -lt launch_call_line ]]
[[ "$end_call_line" == <-> && "$prefix_cleanup_line" == <-> && end_call_line -lt prefix_cleanup_line ]]

print -r -- "mouse acceleration session contract self-test passed"
