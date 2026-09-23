#!/bin/zsh
set -euo pipefail

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
SOURCE_HELPER="$SCRIPT_DIR/privilegedHelpers/stop-idv-login.sh"
STATE_TOOL="/Library/PrivilegedHelperTools/identityv-on-mac/identityv-state-tool"

verify_static() {
  /bin/zsh -n "$SCRIPT_PATH"
  /bin/zsh -n "$SOURCE_HELPER"

  local selected
  for candidate in "$SCRIPT_PATH" "$SOURCE_HELPER"; do
    /usr/bin/grep -Fq 'identityv-state-tool' "$candidate"
    /usr/bin/grep -Fq '"$STATE_TOOL" remove-hosts' "$candidate"
    ! /usr/bin/grep -Fq '/usr/bin/python3' "$candidate"
  done

  # 仅 root 的正式游戏启动跳板应匹配；相近命令是反例，必须保留。
  selected="$(/usr/bin/printf '%s\n' \
    '101 root /Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV --start_from_launcher=1 --is_multi_start' \
    '102 console-user /Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV --start_from_launcher=1 --is_multi_start' \
    '103 root /Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV --start_from_launcher=1' \
    '104 root /Applications/Other.app/Contents/MacOS/launchIdentityV --start_from_launcher=1 --is_multi_start' \
    '105 root /Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV --start_from_launcher=1 --is_multi_start --extra' | \
    /usr/bin/awk '
      $2 == "root" {
        pid = $1
        $1 = ""
        $2 = ""
        sub(/^  */, "")
        if ($0 == "/Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/MacOS/launchIdentityV --start_from_launcher=1 --is_multi_start") print pid
      }
    ')"
  [[ "$selected" == "101" ]] || {
    print -u2 -- "root 启动跳板的精确匹配反例检查失败。"
    return 1
  }

  print -r -- "静态验证通过：停止路径不依赖 Python、使用固定原生状态工具，zsh 语法有效，且只会选择精确 root 启动跳板。"
}

if [[ "${1:-}" == "--verify-static" ]]; then
  verify_static
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  PASSWORDLESS_HELPER="/Library/PrivilegedHelperTools/identityv-on-mac/stop-idv-login.sh"
  if [[ -x "$PASSWORDLESS_HELPER" ]] && /usr/bin/sudo -n "$PASSWORDLESS_HELPER"; then
    exit 0
  fi
  /usr/bin/osascript - "$0" <<'OSA'
on run argv
  do shell script quoted form of (item 1 of argv) & " --root" with administrator privileges
end run
OSA
  exit 0
fi

# The installed root helper writes to /Library/Logs.  The source copy may be
# invoked directly by a normal user, so keep its own log inside that user's home.
if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
  LOG_DIR="/Library/Logs/IdentityVOnMac"
else
  LOG_DIR="${HOME}/Library/Logs/IdentityVOnMac"
fi
LOG_FILE="$LOG_DIR/stop-idv-login.log"
/bin/mkdir -p "$LOG_DIR"
print -r -- "[$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')] stop idv-login requested" >>"$LOG_FILE"

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

terminate_pids() {
  local signal="$1"
  local pids="$2"
  [[ -n "$pids" ]] || return 0
  /usr/bin/printf '%s\n' "$pids" | while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    /bin/kill "-$signal" "$pid" >/dev/null 2>&1 || true
  done
}

pids="$(idv_login_pids)"
trampoline_pids="$(root_game_trampoline_pids)"
terminate_pids TERM "$pids"
terminate_pids TERM "$trampoline_pids"
if [[ -n "$pids$trampoline_pids" ]]; then /bin/sleep 2; fi

pids="$(idv_login_pids)"
trampoline_pids="$(root_game_trampoline_pids)"
terminate_pids KILL "$pids"
terminate_pids KILL "$trampoline_pids"

if [[ -x "$STATE_TOOL" ]]; then
  "$STATE_TOOL" remove-hosts
elif [[ -f /etc/hosts && ! -L /etc/hosts ]]; then
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

print -r -- "已关闭 idv-login 后台进程，并清理兼容模式 hosts 残留。"
