#!/bin/zsh
set -euo pipefail

MODE="${1:---stop-for-restart}"
case "$MODE" in
  --stop-for-restart|--dry-run) ;;
  *) print -u2 -- "usage: $0 [--stop-for-restart|--dry-run]"; exit 64 ;;
esac

CURRENT_UID="$(/usr/bin/id -u)"
GAME_PATTERN='C:\\Games\\IdentityV\\dwrg[.]exe.*--start_from_launcher=1'
LOG_DIR="$HOME/Library/Logs/IdentityVOnMac"
EVENT_LOG="$LOG_DIR/restart-events.log"

matching_pids() {
  local pattern="$1"
  /usr/bin/pgrep -u "$CURRENT_UID" -f "$pattern" 2>/dev/null || true
}

game_pids() {
  matching_pids "$GAME_PATTERN"
}

# A restart may only ask the runner that launched the selected game session to
# exit.  Looking up every app runner by name would also catch another product
# or a future concurrent server.  The Wine command that carries dwrg.exe is a
# direct child of its runner, so walk its short parent chain instead.
runner_pids_for_games() {
  local game_pid="$1"
  local pid parent command depth
  local -A seen
  while IFS= read -r pid; do
    [[ "$pid" == <-> ]] || continue
    parent="$pid"
    for (( depth = 0; depth < 12; depth++ )); do
      parent="$(/bin/ps -o ppid= -p "$parent" 2>/dev/null | /usr/bin/tr -d ' ')"
      [[ "$parent" == <-> && "$parent" != "1" ]] || break
      command="$(/bin/ps -o command= -p "$parent" 2>/dev/null || true)"
      if [[ "$command" == *"/Applications/第五人格启动器.app/Contents/MacOS/launchIdentityVRunner --run"* ]]; then
        if [[ -z "${seen[$parent]:-}" ]]; then
          seen[$parent]=1
          print -r -- "$parent"
        fi
        break
      fi
    done
  done <<< "$game_pid"
}

compact_pids() {
  /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//'
}

signal_pids() {
  local signal_name="$1"
  local pids="$2"
  [[ -n "$pids" ]] || return 0
  /usr/bin/printf '%s\n' "$pids" | while IFS= read -r pid; do
    [[ "$pid" == <-> ]] || continue
    /bin/kill "-$signal_name" "$pid" 2>/dev/null || true
  done
}

wait_for_no_game() {
  local attempts="$1"
  local index
  for (( index = 0; index < attempts; index++ )); do
    [[ -z "$(game_pids)" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

initial_game_pids="$(game_pids)"
initial_runner_pids="$(runner_pids_for_games "$initial_game_pids")"

if [[ "$MODE" == "--dry-run" ]]; then
  print -r -- "game_pids=$(print -r -- "$initial_game_pids" | compact_pids)"
  print -r -- "runner_pids=$(print -r -- "$initial_runner_pids" | compact_pids)"
  exit 0
fi

/bin/mkdir -p "$LOG_DIR"
timestamp="$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')"
print -r -- "[$timestamp] action=restart-button game_pids=$(print -r -- "$initial_game_pids" | compact_pids) runner_pids=$(print -r -- "$initial_runner_pids" | compact_pids)" >>"$EVENT_LOG"

forced_game=0
forced_runner=0
if [[ -n "$initial_game_pids" ]]; then
  signal_pids TERM "$initial_game_pids"
  if ! wait_for_no_game 25; then
    forced_game=1
    signal_pids KILL "$(game_pids)"
    wait_for_no_game 15 || {
      print -u2 -- "无法结束当前第五人格游戏进程。"
      exit 70
    }
  fi
fi

# Let only the runner which owns this game observe the Wine exit, restore Game
# Mode, and close its verified prefix.  Never select every runner by app name:
# another product/server may be intentionally running at the same time.
wait_for_owning_runners() {
  local pids="$1"
  local attempts="$2"
  local index pid
  for (( index = 0; index < attempts; index++ )); do
    local remaining=""
    while IFS= read -r pid; do
      [[ "$pid" == <-> ]] || continue
      /bin/kill -0 "$pid" >/dev/null 2>&1 && remaining+="$pid"$'\n'
    done <<< "$pids"
    [[ -z "$remaining" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

if [[ -n "$initial_runner_pids" ]] && ! wait_for_owning_runners "$initial_runner_pids" 30; then
  forced_runner=1
  signal_pids TERM "$initial_runner_pids"
  if ! wait_for_owning_runners "$initial_runner_pids" 10; then
    signal_pids KILL "$initial_runner_pids"
    wait_for_owning_runners "$initial_runner_pids" 10 || {
      print -u2 -- "游戏已结束，但旧启动进程仍未退出。"
      exit 71
    }
  fi
fi

print -r -- "旧游戏会话已收束（强制游戏=$forced_game，强制启动器=$forced_runner）；IDV Login 保持运行。"
