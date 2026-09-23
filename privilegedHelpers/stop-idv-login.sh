#!/bin/zsh
set -euo pipefail

LOG_DIR="/Library/Logs/IdentityVOnMac"
LOG_FILE="$LOG_DIR/stop-idv-login.log"
STATE_TOOL="/Library/PrivilegedHelperTools/identityv-on-mac/identityv-state-tool"
START_HELPER="/Library/PrivilegedHelperTools/identityv-on-mac/start-idv-login.sh"
source "${0:A:h}/idv-login-job.sh"
SELF_PATH="${0:A}"
LOCK_DIR="$IDV_JOB_DIR/idv-login-start.lock"
LOCK_HELD=0

is_stale_status_helper_command() {
  local user="$1" command="$2"
  [[ "$user" == "root" ]] || return 1
  [[ "$command" == "$START_HELPER --status" || "$command" == "/bin/zsh $START_HELPER --status" ]]
}

stale_status_pid_from_ps_row() {
  local row="$1" pid user command
  # `read` with whitespace IFS consumes any ps alignment padding and assigns
  # the untouched remainder to `command`; no EXTENDED_GLOB dependency and no
  # substring matching of a user's shell command.
  IFS=$' \t\n' read -r pid user command <<< "$row"
  [[ "$pid" == <-> ]] || return 1
  is_stale_status_helper_command "$user" "$command" || return 1
  print -r -- "$pid"
}

if [[ "${1:-}" == "--self-test" ]]; then
  [[ $# == 1 ]] || exit 64
  is_stale_status_helper_command root "$START_HELPER --status"
  is_stale_status_helper_command root "/bin/zsh $START_HELPER --status"
  ! is_stale_status_helper_command root "$START_HELPER"
  ! is_stale_status_helper_command root "/bin/zsh $START_HELPER --status unexpected"
  ! is_stale_status_helper_command exampleuser "$START_HELPER --status"
  [[ "$(stale_status_pid_from_ps_row "  731  root  $START_HELPER --status")" == "731" ]]
  [[ "$(stale_status_pid_from_ps_row $'\t732\troot\t/bin/zsh '"$START_HELPER"$' --status')" == "732" ]]
  ! stale_status_pid_from_ps_row "  733  root  $START_HELPER --status extra"
  ! stale_status_pid_from_ps_row "  734  exampleuser  $START_HELPER --status"
  ! stale_status_pid_from_ps_row "  735  root  /bin/zsh -c '$START_HELPER --status'"
  print 'stop IDV Login stale-status matcher tests passed.'
  exit 0
fi

/bin/mkdir -p "$LOG_DIR"
/usr/bin/printf '[%s] stop idv-login requested\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')" >> "$LOG_FILE"

idv_login_pids() {
  /bin/ps -axo pid=,comm= | /usr/bin/awk '
    {
      pid=$1
      $1=""
      comm=$0
      if (comm ~ /\/IdentityVOnMac\/Components\/idv-login\/.*\/idv-login$/ ||
          comm ~ /\/idv-login-v[0-9][^\/ ]*-mac(-mac)?$/) {
        print pid
      }
    }
  '
}

root_game_trampoline_pids() {
  /bin/ps -axo pid=,user=,command= | /usr/bin/awk '
    {
      pid=$1
      user=$2
      $1=""
      $2=""
      sub(/^  */, "")
      command=$0
      if (user == "root" &&
          command == "/Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV --start_from_launcher=1 --is_multi_start") {
        print pid
      }
    }
  '
}

# Old helpers treated `--status` as a normal start.  Match only root-owned
# copies of that exact old invocation, never a user's shell text or a game.
stale_status_helper_pids() {
  /bin/ps -axo pid=,user=,command= | while IFS= read -r row; do
    stale_status_pid_from_ps_row "$row" || true
  done
}

terminate_pids() {
  local signal="$1"
  local pids="$2"
  [[ -n "$pids" ]] || return 0
  /usr/bin/printf '%s\n' "$pids" | while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    /bin/kill "-$signal" "$pid" >/dev/null 2>&1 || true
  done
}

# Remove the launch capability before killing remaining/legacy children and
# clearing Hosts. The ephemeral job has KeepAlive=false; bootout also prevents
# a later kickstart from reviving a service the user explicitly stopped.
trap release_start_lock EXIT
trap 'release_start_lock; exit 129' HUP
trap 'release_start_lock; exit 130' INT
trap 'release_start_lock; exit 143' TERM
acquire_start_lock
idv_job_remove
pids="$(idv_login_pids)"
trampoline_pids="$(root_game_trampoline_pids)"
stale_status_pids="$(stale_status_helper_pids)"
terminate_pids TERM "$pids"
terminate_pids TERM "$trampoline_pids"
terminate_pids TERM "$stale_status_pids"
if [[ -n "$pids$trampoline_pids$stale_status_pids" ]]; then /bin/sleep 2; fi

pids="$(idv_login_pids)"
trampoline_pids="$(root_game_trampoline_pids)"
stale_status_pids="$(stale_status_helper_pids)"
terminate_pids KILL "$pids"
terminate_pids KILL "$trampoline_pids"
terminate_pids KILL "$stale_status_pids"

for attempt in {1..30}; do
  [[ -z "$(idv_login_pids)" ]] && break
  /bin/sleep 0.1
done
if [[ -n "$(idv_login_pids)" ]]; then
  print -u2 -- 'IDV Login 仍有未退出进程；未清理 hosts。'
  exit 1
fi

if [[ -x "$STATE_TOOL" ]]; then
  "$STATE_TOOL" remove-hosts
elif [[ -f /etc/hosts && ! -L /etc/hosts ]]; then
  # Recovery fallback for a partially removed helper install.  It removes only
  # our three canonical tagged lines; no untagged/user mapping is touched.
  temporary="/etc/.identityv-hosts-cleanup.$$"
  /usr/bin/awk '
    $0 == "127.0.0.1 service.mkey.163.com # identityv-on-mac-compat" { next }
    $0 == "127.0.0.1 sdk-os.mpsdk.easebar.com # identityv-on-mac-compat" { next }
    $0 == "127.0.0.1 mgbsdk.matrix.netease.com # identityv-on-mac-compat" { next }
    { print }
  ' /etc/hosts > "$temporary"
  /usr/sbin/chown "$(/usr/bin/stat -f '%u:%g' /etc/hosts)" "$temporary"
  /bin/chmod "$(/usr/bin/stat -f '%Lp' /etc/hosts)" "$temporary"
  /bin/mv -f "$temporary" /etc/hosts
fi

/usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
/usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
/usr/bin/printf '已关闭 IDV Login 后台进程，并清理兼容模式 hosts 残留。\n'
