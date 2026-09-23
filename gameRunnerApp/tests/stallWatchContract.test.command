#!/bin/zsh
set -u

# Keep this contract runnable from a standalone source archive as well as the
# larger workspace; the runner is a sibling of this test's gameRunnerApp tree.
PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
BASE_TMP="${TMPDIR:-/tmp}"
TEST_ROOT="$(/usr/bin/mktemp -d "$BASE_TMP/identityv-stall-watch.XXXXXX")"
GAME_DIR="$TEST_ROOT/game"
CONFIG_DIR="$TEST_ROOT/config"
LOG_FILE="$TEST_ROOT/runner.log"
PRODUCT="test"
WINDOWS_GAME_ROOT="IdentityV"
LOW_FREQUENCY_SAMPLE_INTERVAL_SECONDS=10
LOW_FREQUENCY_LAST_SAMPLE_EPOCH=0
export STALL_TEST_PS_ARGS="$TEST_ROOT/ps.args"
export STALL_TEST_LSAPPINFO_ARGS="$TEST_ROOT/lsappinfo.args"
export STALL_TEST_SAMPLE_MODE=burst

cleanup_test() {
  [[ -n "${STALL_SAMPLE_PID:-}" && "$STALL_SAMPLE_PID" == <-> ]] && {
    /bin/kill -KILL "$STALL_SAMPLE_PID" >/dev/null 2>&1 || true
  }
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  print -u2 -- "stallWatchContract: $*"
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"
}

assert_contains() {
  /usr/bin/grep -Fq -- "$1" "$2" || fail "'$1' missing from $2"
}

/bin/mkdir -p "$GAME_DIR" "$CONFIG_DIR" "$TEST_ROOT/mock"
: >"$LOG_FILE"
: >"$STALL_TEST_PS_ARGS"
: >"$STALL_TEST_LSAPPINFO_ARGS"

cat >"$TEST_ROOT/mock/ps" <<'EOF'
#!/bin/zsh
print -r -- "$*" >>"$STALL_TEST_PS_ARGS"
uid="$(/usr/bin/id -u)"
if [[ "$*" == *"pid=,uid=,%cpu=,rss=,state=,command="* ]]; then
  print -r -- "4242 $uid 2.5 123456 S C:\\Games\\IdentityV\\dwrg.exe --start_from_launcher=1 --is_multi_start"
elif [[ "$*" == *"pid=,uid=,%cpu=,command="* ]]; then
  print -r -- "4242 $uid 2.5 C:\\Games\\IdentityV\\dwrg.exe --start_from_launcher=1 --is_multi_start"
elif [[ "$*" == *"pid=,uid=,command="* ]]; then
  print -r -- "4242 $uid C:\\Games\\IdentityV\\dwrg.exe --start_from_launcher=1 --is_multi_start"
fi
EOF
chmod 700 "$TEST_ROOT/mock/ps"

cat >"$TEST_ROOT/mock/lsappinfo" <<'EOF'
#!/bin/zsh
print -r -- "$*" >>"$STALL_TEST_LSAPPINFO_ARGS"
if [[ "$1" == front ]]; then
  print -r -- 'ASN:0xdeadbeef'
elif [[ "$1" == info ]]; then
  print -r -- '    pid = 4242'
fi
EOF
chmod 700 "$TEST_ROOT/mock/lsappinfo"

cat >"$TEST_ROOT/mock/sample" <<'EOF'
#!/bin/zsh
if [[ "$STALL_TEST_SAMPLE_MODE" == slow ]]; then
  exec /bin/sleep 2
fi
if [[ "$STALL_TEST_SAMPLE_MODE" == tiny ]]; then
  print -r -- 'small sample'
  exit 0
fi
for i in {1..10000}; do
  print -r -- 'bounded sample frame'
done
EOF
chmod 700 "$TEST_ROOT/mock/sample"

# Extract only the production forensic block; sourcing the complete runner would
# run its prefix setup and is intentionally outside this contract test.
eval "$(/usr/bin/sed -n '/^# --- forensic freeze evidence/,/^set_game_mode_on() {/p' "$RUNNER" | /usr/bin/sed '$d')"
STALL_PS_BIN="$TEST_ROOT/mock/ps"
STALL_LSAPPINFO_BIN="$TEST_ROOT/mock/lsappinfo"
STALL_SAMPLE_BIN="$TEST_ROOT/mock/sample"
STALL_SAMPLE_MAX_BYTES=1024
STALL_SAMPLE_TIMEOUT_SECONDS=1
STALL_MAX_SNAPSHOTS=2
STALL_COOLDOWN_SECONDS=600

wait_for_stall_worker() {
  local tries=0
  while [[ "$STALL_SAMPLE_WORKER_PID" == <-> ]] && /bin/kill -0 "$STALL_SAMPLE_WORKER_PID" >/dev/null 2>&1; do
    (( tries++ < 60 )) || fail "stall worker did not finish"
    /bin/sleep 0.05
  done
  stall_reap_snapshot_worker || fail "stall worker still active"
}

old_marker='2026-09-20 00:00:00 OCCUR ANR old-baseline'
print -r -- "$old_marker" >"$GAME_DIR/log.txt"
print -r -- "$old_marker" >>"$GAME_DIR/log.txt"
initialize_stall_watch

# Ordinary writes after the baseline do not create an ANR event.
print -rn -- 'ordinary partial line' >>"$GAME_DIR/log.txt"
update_stall_watch 4242
assert_equal "$(/usr/bin/grep -c 'new OCCUR ANR' "$LOG_FILE" 2>/dev/null || true)" 0
print -r -- 'completed' >>"$GAME_DIR/log.txt"
print -r -- 'ordinary game log line' >>"$GAME_DIR/log.txt"
update_stall_watch 4242
assert_equal "$(/usr/bin/grep -c 'new OCCUR ANR' "$LOG_FILE" 2>/dev/null || true)" 0

# A genuinely appended marker creates one bounded snapshot; repeating its line
# is the same event and must not create a second one.
new_marker='2026-09-20 00:00:01 OCCUR ANR new-event'
STALL_TEST_SAMPLE_MODE=slow
print -r -- "$new_marker" >>"$GAME_DIR/log.txt"
started="$(/bin/date +%s)"
update_stall_watch 4242
[[ "$STALL_SAMPLE_WORKER_PID" == <-> ]] || fail "ANR collection did not dispatch a worker"
(( $(/bin/date +%s) - started <= 1 )) || fail "ANR collection blocked the monitor"
wait_for_stall_worker
assert_contains 'sample_timed_out=1' "$CONFIG_DIR/Diagnostics/stalls/latest/context.txt"
STALL_TEST_SAMPLE_MODE=burst
print -r -- "$new_marker" >>"$GAME_DIR/log.txt"
update_stall_watch 4242
assert_equal "$(/usr/bin/grep -c 'new OCCUR ANR' "$LOG_FILE" 2>/dev/null || true)" 1

# A different event is recorded during the shared cooldown but does not sample.
cooldown_marker='2026-09-20 00:00:02 OCCUR ANR cooldown-event'
print -r -- "$cooldown_marker" >>"$GAME_DIR/log.txt"
update_stall_watch 4242
assert_equal "$(/usr/bin/grep -c 'new OCCUR ANR' "$LOG_FILE" 2>/dev/null || true)" 2
assert_equal "$(find "$CONFIG_DIR/Diagnostics/stalls" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" 1

# Rotation keeps the seeded old marker quiet while a new marker in the new
# inode is visible.  Truncation is covered by the next append on that inode.
/bin/mv "$GAME_DIR/log.txt" "$GAME_DIR/log_old_0.txt"
print -r -- "$old_marker" >"$GAME_DIR/log.txt"
rotated_marker='2026-09-20 00:00:03 OCCUR ANR rotated-event'
print -r -- "$rotated_marker" >>"$GAME_DIR/log.txt"
STALL_TEST_SAMPLE_MODE=tiny
STALL_LAST_SNAPSHOT_EPOCH=0
update_stall_watch 4242
wait_for_stall_worker
assert_contains 'sample_exit_code=0' "$CONFIG_DIR/Diagnostics/stalls/latest/context.txt"
assert_equal "$(/usr/bin/grep -c 'new OCCUR ANR' "$LOG_FILE" 2>/dev/null || true)" 3

: >"$GAME_DIR/log.txt"
truncated_marker='2026-09-20 00:00:04 OCCUR ANR truncated-event'
print -r -- "$truncated_marker" >>"$GAME_DIR/log.txt"
STALL_LAST_SNAPSHOT_EPOCH=0
update_stall_watch 4242
wait_for_stall_worker
assert_equal "$(/usr/bin/grep -c 'new OCCUR ANR' "$LOG_FILE" 2>/dev/null || true)" 4
assert_equal "$(find "$CONFIG_DIR/Diagnostics/stalls" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" 2

# The process lookup uses the real target PID and UID fields, while front ASN
# is resolved through lsappinfo info to that PID rather than string matching.
assert_equal "$(sample_stall_cpu 4242)" 2.5
stall_front_pid_is 4242 || fail "front ASN did not resolve to target PID"
assert_contains '-p 4242' "$STALL_TEST_PS_ARGS"
assert_contains '-o pid=,uid=,%cpu=,command=' "$STALL_TEST_PS_ARGS"
assert_contains 'info ASN:0xdeadbeef' "$STALL_TEST_LSAPPINFO_ARGS"
LOW_FREQUENCY_LAST_SAMPLE_EPOCH=0
append_low_frequency_sample 4242
assert_contains 'pid=4242 cpu_pct=2.5' "$LOG_FILE"

# Sampling is bounded in both output size and wall time, and has no lingering
# child after the lifecycle cleanup hook.
for sample_file in "$CONFIG_DIR"/Diagnostics/stalls/*/sample.txt(N); do
  (( $(/usr/bin/stat -f '%z' "$sample_file") <= STALL_SAMPLE_MAX_BYTES )) || fail "sample exceeded byte cap"
done
STALL_TEST_SAMPLE_MODE=slow
STALL_SAMPLE_TIMEOUT_SECONDS=10
started="$(/bin/date +%s)"
STALL_LAST_SNAPSHOT_EPOCH=0
collect_stall_snapshot 'timeout-check' 4242
[[ "$STALL_SAMPLE_WORKER_PID" == <-> ]] || fail "timeout sample did not dispatch a worker"
cleanup_worker_pid="$STALL_SAMPLE_WORKER_PID"
for tries in {1..20}; do
  [[ -f "$STALL_SAMPLE_WORKER_DIR/.sample.pid" ]] && break
  /bin/sleep 0.05
done
cleanup_child_pid="$(/bin/cat "$STALL_SAMPLE_WORKER_DIR/.sample.pid" 2>/dev/null || true)"
elapsed=$(( $(/bin/date +%s) - started ))
(( elapsed <= 3 )) || fail "async sample dispatch took ${elapsed}s"
cleanup_stall_watch
/bin/kill -0 "$cleanup_worker_pid" >/dev/null 2>&1 && fail "cleanup left worker alive"
[[ "$cleanup_child_pid" == <-> ]] && /bin/kill -0 "$cleanup_child_pid" >/dev/null 2>&1 && fail "cleanup left sample child alive"

print -- 'stallWatchContract: PASS'
