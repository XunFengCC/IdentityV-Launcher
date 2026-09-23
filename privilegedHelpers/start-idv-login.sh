#!/bin/zsh
set -euo pipefail

COMPONENT_ROOT="/Library/Application Support/IdentityVOnMac/Components/idv-login"
IDV_BIN="$COMPONENT_ROOT/current/idv-login"
HELPER_DIR="/Library/PrivilegedHelperTools/identityv-on-mac"
GAME_BRIDGE="$HELPER_DIR/launch-game-as-console-user"
STATE_TOOL="$HELPER_DIR/identityv-state-tool"
readonly READINESS_TIMEOUT_SECONDS=300
readonly RESTART_GRACE_SECONDS=10
readonly IDV_LOGIN_STATUS_CONTRACT="7"
readonly MANAGED_DOMAINS=(
  "service.mkey.163.com"
  "sdk-os.mpsdk.easebar.com"
  "mgbsdk.matrix.netease.com"
)
readonly HOSTS_TAG="identityv-on-mac-compat"
READINESS_FIXTURE_DIR=""
MODE="start"
LOCK_DIR="/var/run/identityv-on-mac/idv-login-start.lock"
LOCK_HELD=0
SELF_PATH="${0:A}"
source "${SELF_PATH:h}/idv-login-job.sh"

if (( $# > 0 )); then
  case "$1" in
    --status)
      [[ $# == 1 ]] || { print -u2 -- "--status 不接受额外参数。"; exit 64; }
      MODE="status"
      ;;
    --contract)
      [[ $# == 1 ]] || { print -u2 -- "--contract 不接受额外参数。"; exit 64; }
      print -r -- "IDV_LOGIN_STATUS_CONTRACT=$IDV_LOGIN_STATUS_CONTRACT"
      exit 0
      ;;
    --readiness-fixture)
      [[ $# == 2 && "$2" == /* && -d "$2" && ! -L "$2" ]] || { print -u2 -- "--readiness-fixture 必须是绝对普通目录。"; exit 64; }
      MODE="fixture"
      READINESS_FIXTURE_DIR="$2"
      ;;
    --startup-sequence-fixture)
      [[ $# == 2 && "$2" == /* && -d "$2" && ! -L "$2" ]] || exit 64
      MODE="sequence-fixture"
      READINESS_FIXTURE_DIR="$2"
      ;;
    *)
      print -u2 -- "参数无效。"
      exit 64
      ;;
  esac
fi

log() {
  /usr/bin/printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG_FILE"
}

resolve_console_user() {
  local account_uid home_owner
  USER_NAME="$(/usr/bin/stat -f '%Su' /dev/console)"
  USER_ID="$(/usr/bin/stat -f '%u' /dev/console)"
  [[ "$USER_NAME" != "root" && "$USER_NAME" != "loginwindow" && -n "$USER_NAME" ]] || {
    /usr/bin/printf '未检测到已登录的 macOS 桌面用户。\n' >&2
    return 1
  }
  [[ "$USER_ID" == <-> && "$USER_ID" -ge 500 ]] || {
    /usr/bin/printf '当前桌面用户 UID 无效。\n' >&2
    return 1
  }
  account_uid="$(/usr/bin/dscl . -read "/Users/$USER_NAME" UniqueID 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')"
  USER_HOME="$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')"
  [[ "$account_uid" == "$USER_ID" && "$USER_HOME" == /* && -d "$USER_HOME" ]] || {
    /usr/bin/printf '当前桌面用户账户信息异常。\n' >&2
    return 1
  }
  home_owner="$(/usr/bin/stat -f '%u' "$USER_HOME")"
  [[ "$home_owner" == "$USER_ID" ]] || {
    /usr/bin/printf '当前桌面用户主目录所有者异常。\n' >&2
    return 1
  }
  APP_SUPPORT="$USER_HOME/Library/Application Support"
  IDV_DIR="$APP_SUPPORT/idv-login"
  CONFIG="$IDV_DIR/config.json"
  LOG_FILE="$IDV_DIR/idv-login-launcher.log"
}

prepare_user_runtime_directory() {
  /bin/mkdir -p "$IDV_DIR"
  /usr/sbin/chown "$USER_ID":staff "$IDV_DIR" 2>/dev/null || true
}


process_snapshot() {
  if [[ -n "$READINESS_FIXTURE_DIR" ]]; then
    /bin/cat "$READINESS_FIXTURE_DIR/processes.txt"
  else
    /bin/ps -axo pid=,ppid=,command=
  fi
}

idv_login_pids_from() {
  /usr/bin/awk '
    {
      pid=$1
      $1=""; $2=""
      sub(/^  */, "")
      comm=$0
      if (comm ~ /^\/Library\/Application Support\/IdentityVOnMac\/Components\/idv-login\/[^\/[:space:]]+\/idv-login([[:space:]]|$)/ ||
          comm ~ /^\/[^[:space:]]*\/idv-login-v[0-9][^\/[:space:]]*-mac(-mac)?([[:space:]]|$)/) {
        print pid
      }
    }
  '
}

listener_snapshot() {
  if [[ -n "$READINESS_FIXTURE_DIR" ]]; then
    /bin/cat "$READINESS_FIXTURE_DIR/listeners.txt"
  else
    /usr/sbin/lsof -nP -iTCP:443 -sTCP:LISTEN -Fpn 2>/dev/null || true
  fi
}

hosts_path() {
  if [[ -n "$READINESS_FIXTURE_DIR" ]]; then
    print -r -- "$READINESS_FIXTURE_DIR/hosts"
  else
    print -r -- "/etc/hosts"
  fi
}

listener_belongs_to_component_tree() {
  local listener_pid="$1" component_pids="$2" snapshot="$3" roots_one_line
  # BSD awk rejects a literal newline inside a -v assignment.  IDV Login uses
  # two same-path root processes in normal operation, so flatten the already
  # numeric PID list before passing it to awk.
  roots_one_line="$(/usr/bin/printf '%s\n' "$component_pids" | /usr/bin/awk '$1 ~ /^[0-9]+$/ { printf "%s ", $1 }')"
  [[ -n "$roots_one_line" ]] || return 1
  /usr/bin/awk -v target="$listener_pid" -v roots="$roots_one_line" '
    BEGIN {
      count = split(roots, rootList, /[[:space:]]+/)
      for (i = 1; i <= count; i++) if (rootList[i] != "") root[rootList[i]] = 1
    }
    NF >= 3 { ppid[$1] = $2 }
    END {
      pid = target
      for (guard = 0; guard < 256 && pid != ""; guard++) {
        if (pid in root) exit 0
        if (!(pid in ppid)) break
        pid = ppid[pid]
      }
      exit 1
    }
  ' <<< "$snapshot"
}

hosts_are_exactly_managed() {
  local path="$1" allow_missing="${2:-0}" domain
  [[ -f "$path" && ! -L "$path" ]] || return 1
  for domain in "${MANAGED_DOMAINS[@]}"; do
    /usr/bin/awk -v domain="$domain" -v tag="$HOSTS_TAG" -v allowMissing="$allow_missing" '
      {
        raw=$0
        sub(/\r$/, "", raw)
        hash=index(raw, "#")
        if (hash > 0) {
          content=substr(raw, 1, hash - 1)
          comment=substr(raw, hash + 1)
        } else {
          content=raw
          comment=""
        }
        sub(/^[[:space:]]+/, "", content)
        sub(/[[:space:]]+$/, "", content)
        sub(/^[[:space:]]+/, "", comment)
        sub(/[[:space:]]+$/, "", comment)
        count=split(content, fields, /[[:space:]]+/)
        hasDomain=0
        for (i=2; i<=count; i++) if (fields[i] == domain) hasDomain=1
        if (hasDomain) {
          valid=(count == 2 && fields[1] == "127.0.0.1" && fields[2] == domain && (hash == 0 || comment == tag))
          if (valid) acceptedCount++
          else polluted=1
        }
      }
      END { exit !(!polluted && (acceptedCount == 1 || (allowMissing && acceptedCount == 0))) }
    ' "$path" || return 1
  done
}

readiness_state() {
  local processes component_pids listener_data listener_pid host_file
  processes="$(process_snapshot)"
  component_pids="$(idv_login_pids_from <<< "$processes")"
  [[ -n "$component_pids" ]] || { print -r -- "not-running"; return 0; }
  host_file="$(hosts_path)"
  hosts_are_exactly_managed "$host_file" || { print -r -- "misconfigured"; return 0; }
  listener_data="$(listener_snapshot)"
  while IFS= read -r listener_pid; do
    [[ "$listener_pid" == <-> ]] || continue
    if listener_belongs_to_component_tree "$listener_pid" "$component_pids" "$processes"; then
      print -r -- "ready"
      return 0
    fi
  done < <(/usr/bin/awk '/^p[0-9]+$/ { pid=substr($0,2); next } /^n127\.0\.0\.1:443$/ { if (pid != "") print pid }' <<< "$listener_data")
  if /usr/bin/awk '/^n127\.0\.0\.1:443$/ { found=1 } END { exit !found }' <<< "$listener_data"; then
    print -r -- "misconfigured"
  else
    print -r -- "starting"
  fi
}

startup_observation() {
  local processes component_pids listener_data listener_pid owns_listener=0
  processes="$(process_snapshot)"
  component_pids="$(idv_login_pids_from <<< "$processes")"
  # Upstream removes its old mappings before CA generation and restores them
  # after authorization. Missing mappings may recover; foreign/duplicate or
  # non-loopback mappings must still fail immediately.
  hosts_are_exactly_managed "$(hosts_path)" 1 || { print misconfigured; return; }
  listener_data="$(listener_snapshot)"
  while IFS= read -r listener_pid; do
    [[ "$listener_pid" == <-> ]] || continue
    if listener_belongs_to_component_tree "$listener_pid" "$component_pids" "$processes"; then
      owns_listener=1
    else
      print misconfigured
      return
    fi
  done < <(/usr/bin/awk '/^p[0-9]+$/ { pid=substr($0,2); next } /^n(127\.0\.0\.1|\*|\[::\]):443$/ { if (pid != "") print pid }' <<< "$listener_data")
  [[ -n "$component_pids" ]] || { print not-running; return; }
  # Only a security trust request in this exact managed component tree can
  # suspend startup time. Foreign Hosts/listeners still fail above.
  local authorization_pid
  while IFS= read -r authorization_pid; do
    if listener_belongs_to_component_tree "$authorization_pid" "$component_pids" "$processes"; then
      print authorization
      return
    fi
  done < <(/usr/bin/awk '
    { pid=$1; $1=""; $2=""; sub(/^  */, "")
      if ($0 ~ /^(\/usr\/bin\/)?security[[:space:]]+add-trusted-cert[[:space:]]/) print pid
    }' <<< "$processes")
  if (( owns_listener )) && hosts_are_exactly_managed "$(hosts_path)"; then
    # Preserve the final exact loopback listener and ownership requirement.
    readiness_state
  else
    print starting
  fi
}

STARTUP_ABSENT_SINCE=-1
STARTUP_DECISION=starting
STARTUP_AUTHORIZATION_ACTIVE=0
STARTUP_AUTHORIZATION_SEEN=0
STARTUP_DEADLINE_OFFSET=0
startup_step() {
  local observation="$1" elapsed="$2"
  STARTUP_DECISION="$observation"
  if [[ "$observation" == authorization ]]; then
    STARTUP_AUTHORIZATION_ACTIVE=1
    STARTUP_AUTHORIZATION_SEEN=1
    STARTUP_ABSENT_SINCE=-1
    STARTUP_DEADLINE_OFFSET=$elapsed
    STARTUP_DECISION=starting
    return 0
  fi
  if (( STARTUP_AUTHORIZATION_ACTIVE )); then
    STARTUP_AUTHORIZATION_ACTIVE=0
    STARTUP_DEADLINE_OFFSET=$elapsed
  fi
  case "$observation" in
    ready|misconfigured) return 0 ;;
    not-running)
      (( STARTUP_ABSENT_SINCE >= 0 )) || STARTUP_ABSENT_SINCE=$elapsed
      (( elapsed - STARTUP_ABSENT_SINCE < RESTART_GRACE_SECONDS )) || return 0
      ;;
    starting) STARTUP_ABSENT_SINCE=-1 ;;
  esac
  if (( elapsed - STARTUP_DEADLINE_OFFSET >= READINESS_TIMEOUT_SECONDS )); then
    STARTUP_DECISION=timeout
  else
    STARTUP_DECISION=starting
  fi
}

if [[ "$MODE" == "sequence-fixture" ]]; then
  sequence_root="$READINESS_FIXTURE_DIR"
  previous_elapsed=-1
  while read -r elapsed frame; do
    [[ "$elapsed" == <-> && "$frame" == <-> && "$elapsed" -ge "$previous_elapsed" ]] || exit 64
    READINESS_FIXTURE_DIR="$sequence_root/$frame"
    [[ -d "$READINESS_FIXTURE_DIR" && ! -L "$READINESS_FIXTURE_DIR" ]] || exit 64
    startup_step "$(startup_observation)" "$elapsed"
    previous_elapsed=$elapsed
    [[ "$STARTUP_DECISION" == starting ]] || break
  done < "$sequence_root/timeline.txt"
  print -r -- "IDV_LOGIN_STARTUP=$STARTUP_DECISION"
  exit 0
fi

if [[ "$MODE" == "fixture" ]]; then
  state="$(readiness_state)"
  print -r -- "IDV_LOGIN_READINESS=$state"
  exit 0
fi

if [[ "$MODE" == "status" ]]; then
  # Status is intentionally read-only: it resolves the active account/path
  # for consistency with start mode but does not create or chown its runtime
  # directory, alter Hosts, or start a process.
  resolve_console_user
  state="$(readiness_state)"
  print -r -- "IDV_LOGIN_READINESS=$state"
  exit 0
fi

resolve_console_user
trap release_start_lock EXIT
trap 'release_start_lock; exit 129' HUP
trap 'release_start_lock; exit 130' INT
trap 'release_start_lock; exit 143' TERM
acquire_start_lock
prepare_user_runtime_directory

validate_component() {
  local resolved owner bridge_owner bridge_mode state_owner state_mode
  [[ -x "$IDV_BIN" ]] || {
    log "component validation failed: current idv-login is missing"
    /usr/bin/printf 'IDV Login 组件未安装，请先运行整体组件更新。\n' >&2
    return 1
  }
  resolved="$(/bin/realpath "$IDV_BIN" 2>/dev/null || true)"
  [[ "$resolved" == "$COMPONENT_ROOT"/*/idv-login ]] || {
    log "component validation failed: unexpected target $resolved"
    /usr/bin/printf 'IDV Login 组件 current 指针异常。\n' >&2
    return 1
  }
  owner="$(/usr/bin/stat -f '%u' "$resolved")"
  [[ "$owner" == "0" ]] || {
    log "component validation failed: binary uid=$owner"
    /usr/bin/printf 'IDV Login 组件所有者异常。\n' >&2
    return 1
  }
  [[ -x "$GAME_BRIDGE" ]] || {
    log "component validation failed: game bridge missing"
    /usr/bin/printf '游戏用户态启动桥缺失；请重新安装 IDV Login 组件。\n' >&2
    return 1
  }
  bridge_owner="$(/usr/bin/stat -f '%u' "$GAME_BRIDGE")"
  bridge_mode="$(/usr/bin/stat -f '%Lp' "$GAME_BRIDGE")"
  [[ "$bridge_owner" == "0" && "$bridge_mode" == "755" ]] || {
    log "component validation failed: game bridge owner=$bridge_owner mode=$bridge_mode"
    /usr/bin/printf '游戏用户态启动桥权限异常；请重新安装 IDV Login 组件。\n' >&2
    return 1
  }
  [[ -x "$STATE_TOOL" ]] || {
    log "component validation failed: native state tool missing"
    /usr/bin/printf 'IDV Login 原生状态工具缺失；请重新安装组件。\n' >&2
    return 1
  }
  state_owner="$(/usr/bin/stat -f '%u' "$STATE_TOOL")"
  state_mode="$(/usr/bin/stat -f '%Lp' "$STATE_TOOL")"
  [[ "$state_owner" == "0" && "$state_mode" == "755" ]] || {
    log "component validation failed: state tool owner=$state_owner mode=$state_mode"
    /usr/bin/printf 'IDV Login 原生状态工具权限异常；请重新安装组件。\n' >&2
    return 1
  }
}

ensure_compat_hosts() {
  # Alpha only supports the explicit tagged Hosts compatibility mode.  It never
  # installs a CA or changes macOS's system proxy settings.
  "$STATE_TOOL" ensure-hosts
}

validate_component

# Bounded native JSON migration preserves account/channel records, sets only
# compat mode and the fixed h55 bridge, and creates the minimal clean-install
# record when config.json does not exist yet.
"$STATE_TOOL" prepare-config --home "$USER_HOME"
log "idv-login config prepared with the fixed game bridge and compat mode"

ensure_compat_hosts

if [[ -n "$(idv_login_pids_from <<< "$(process_snapshot)")" ]]; then
  log "idv-login already running; leaving shared proxy/account service intact"
  /usr/bin/printf 'IDV Login 已在后台运行。\n'
else
  log "starting shared idv-login proxy/account service via $IDV_JOB_SERVICE"
  idv_job_start "$IDV_BIN" "$USER_HOME" "$USER_NAME" "$LOG_FILE" || {
    log 'launchd bootstrap failed; no game launch requested'
    "$HELPER_DIR/stop-idv-login.sh" >/dev/null 2>&1 || log 'bootstrap failure cleanup also failed; inspect the fixed launchd service and hosts'
    print -u2 -- 'IDV Login 独立后台任务启动失败；请查看组件日志。'
    exit 1
  }
  # Readiness uses a fresh executable/ancestry snapshot, never the PID of the
  # short-lived launchctl client. No consumer uses the old shell-$! pid file.
fi

started_at="$(/bin/date +%s)"
while true; do
  startup_step "$(startup_observation)" "$(( $(/bin/date +%s) - started_at ))"
  state="$STARTUP_DECISION"
  case "$state" in
    ready)
      log "idv-login readiness confirmed: managed process tree owns 127.0.0.1:443 and canonical hosts are present"
      # Upstream imports a newly generated CA, but skips re-importing a valid
      # retained PEM after uninstall revoked System trust. The native tool
      # requests macOS authorization for exactly that missing public CA, then
      # records exact ownership. Status mode never enters this mutation path.
      if "$STATE_TOOL" ensure-idv-login-ca --home "$USER_HOME"; then
        :
      else
        ca_status=$?
        if (( ca_status == 75 )); then
          log "system authorization withdrawn; retaining a resumable authorization request"
          "$HELPER_DIR/stop-idv-login.sh" >/dev/null 2>&1 || true
          print -u2 -r -- "IDV_LOGIN_AUTHORIZATION=waiting"
          exit 75
        fi
        log "IDV Login readiness reached but System CA ownership record was not confirmed"
        "$HELPER_DIR/stop-idv-login.sh" >/dev/null 2>&1 || true
        /usr/bin/printf 'IDV Login 的系统证书授权尚未完成；请重新启动组件并完成 macOS 授权。若仍失败，请查看组件日志。\n' >&2
        exit 1
      fi
      /usr/bin/printf 'IDV Login 已就绪；本机登录代理可用。\n'
      exit 0
      ;;
    not-running)
      if (( STARTUP_AUTHORIZATION_SEEN )); then
        log "component exited after system authorization; waiting for an explicit retry"
        "$HELPER_DIR/stop-idv-login.sh" >/dev/null 2>&1 || true
        print -u2 -r -- "IDV_LOGIN_AUTHORIZATION=waiting"
        exit 75
      fi
      log "idv-login exited before readiness"
      /usr/bin/printf 'IDV Login 在本机登录代理就绪前退出；请查看组件日志或重新安装固定组件。\n' >&2
      exit 1
      ;;
    misconfigured)
      log "idv-login readiness rejected: hosts mapping or 443 listener ownership is not exact"
      /usr/bin/printf 'IDV Login 未就绪：受管 Hosts 映射或 127.0.0.1:443 监听归属异常；未自动重试。\n' >&2
      exit 1
      ;;
    timeout)
      log "idv-login readiness timeout after ${READINESS_TIMEOUT_SECONDS}s"
      /usr/bin/printf 'IDV Login 在 %s 秒内未就绪；请完成系统证书授权后手动重试，或查看组件日志。\n' "$READINESS_TIMEOUT_SECONDS" >&2
      exit 1
      ;;
    starting)
      /bin/sleep 1
      ;;
  esac
done
