#!/bin/zsh
# Shared by the root-owned start/stop helpers. No side effects when sourced.
# A reparented child still carries its launcher's responsibility/coalition.
# Bootstrap an explicit system job instead, with no inherited App environment.
# Keep this job ephemeral: it starts only on request, not at boot/login, and
# never resurrects itself after the user selects Stop.
readonly IDV_JOB_LABEL="com.fengyin.identityv.idv-login"
readonly IDV_JOB_SERVICE="system/$IDV_JOB_LABEL"
readonly IDV_LEGACY_JOB_SERVICE="system/com.xunfeng.identityv.idv-login"
readonly IDV_JOB_DIR="/var/run/identityv-on-mac"
readonly IDV_JOB_PLIST="$IDV_JOB_DIR/idv-login.plist"

release_start_lock() {
  (( LOCK_HELD == 1 )) || return 0
  [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || return 0
  owner="$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  # Never remove a lock that has been replaced by a later process.
  [[ "$owner" == "$$" ]] || return 0
  /bin/rm -rf -- "$LOCK_DIR"
  LOCK_HELD=0
}

lock_owner_is_live_lifecycle_helper() {
  local owner="$1" command candidate
  [[ "$owner" == <-> ]] || return 1
  /bin/kill -0 "$owner" 2>/dev/null || return 1
  command="$(/bin/ps -p "$owner" -o command= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//')"
  for candidate in "${SELF_PATH:h}/start-idv-login.sh" "${SELF_PATH:h}/stop-idv-login.sh"; do
    [[ "$command" == "$candidate" || "$command" == "/bin/zsh $candidate" ]] && return 0
  done
  return 1
}

acquire_start_lock() {
  local owner lock_mtime now
  /bin/mkdir -p "${LOCK_DIR:h}" || return 1
  [[ ! -L "${LOCK_DIR:h}" && "$(/usr/bin/stat -f '%u' "${LOCK_DIR:h}")" == "$EUID" ]] || return 1
  while ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; do
    [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || {
      /usr/bin/printf 'IDV Login 启动锁路径异常；请重新安装组件。\n' >&2
      return 1
    }
    owner="$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    # `mkdir` is the atomic acquisition.  Give its owner a brief moment to
    # publish the pid before treating an empty directory as stale, otherwise a
    # second caller could delete a lock between mkdir and the pid write.
    if [[ -z "$owner" ]]; then
      lock_mtime="$(/usr/bin/stat -f '%m' "$LOCK_DIR" 2>/dev/null || true)"
      now="$(/bin/date +%s)"
      if [[ "$lock_mtime" == <-> && $(( now - lock_mtime )) -lt 5 ]]; then
        /bin/sleep 1
        continue
      fi
    fi
    if ! lock_owner_is_live_lifecycle_helper "$owner"; then
      # The only recoverable stale state is our exact, ordinary lock directory.
      /bin/rm -rf -- "$LOCK_DIR"
      continue
    fi
    # A start helper invokes Stop for its own error cleanup while holding this
    # lock. Borrow that parent lock; external start/stop calls remain serialized.
    if [[ "$SELF_PATH" == */stop-idv-login.sh && "$owner" == "$PPID" ]]; then
      return 0
    fi
    # A live start helper may be waiting for the person in a system dialog.
    # Do not time out its followers; dead owners are recovered above.
    /bin/sleep 1
  done
  /usr/bin/printf '%s\n' "$$" > "$LOCK_DIR/pid" || return 1
  LOCK_HELD=1
  # The caller must install EXIT/signal traps at script scope. In zsh an EXIT
  # trap installed *inside this function* runs when the function returns,
  # silently releasing the lock before the protected transaction starts.
}

idv_job_loaded() { /bin/launchctl print "$1" >/dev/null 2>&1; }

idv_job_write_plist() {
  local destination="$1" binary="$2" user_home="$3" user_name="$4" output="$5"
  # plutil escapes values, including home paths with spaces/XML characters.
  # Explicit environment prevents launcher identity and DYLD variables leaking
  # into this independently owned job. The component still needs the console
  # user's application-data paths while serving the privileged local port.
  # This function is invoked under `if !`; zsh disables errexit in that
  # context. Propagate every failed field write, not just the final plist lint.
  /usr/bin/plutil -create xml1 "$destination" || return 1
  /usr/bin/plutil -insert Label -string "$IDV_JOB_LABEL" "$destination" || return 1
  /usr/bin/plutil -insert ProgramArguments -json '[]' "$destination" || return 1
  /usr/bin/plutil -insert ProgramArguments.0 -string "$binary" "$destination" || return 1
  /usr/bin/plutil -insert EnvironmentVariables -json '{}' "$destination" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.HOME -string "$user_home" "$destination" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.USER -string "$user_name" "$destination" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.LOGNAME -string "$user_name" "$destination" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.PROGRAMDATA -string "$user_home/Library/Application Support" "$destination" || return 1
  /usr/bin/plutil -insert EnvironmentVariables.PATH -string '/usr/bin:/bin:/usr/sbin:/sbin' "$destination" || return 1
  /usr/bin/plutil -insert StandardInPath -string /dev/null "$destination" || return 1
  /usr/bin/plutil -insert StandardOutPath -string "$output" "$destination" || return 1
  /usr/bin/plutil -insert StandardErrorPath -string "$output" "$destination" || return 1
  /usr/bin/plutil -insert RunAtLoad -bool true "$destination" || return 1
  /usr/bin/plutil -insert KeepAlive -bool false "$destination" || return 1
  /usr/bin/plutil -insert Nice -integer 5 "$destination" || return 1
  /usr/bin/plutil -lint "$destination" >/dev/null
}

idv_job_remove() {
  local attempt service
  # An upgraded helper must remove both the current job and a live job left by
  # the old installation before replacing the shared plist or cleaning Hosts.
  # Never proceed if either registration can still restart the proxy.
  for service in "$IDV_JOB_SERVICE" "$IDV_LEGACY_JOB_SERVICE"; do
    if idv_job_loaded "$service"; then
      /bin/launchctl bootout "$service" || {
        # A concurrently completed exit/removal is harmless; a still-loaded
        # job is not.
        idv_job_loaded "$service" && return 1
      }
      for attempt in {1..50}; do
        idv_job_loaded "$service" || break
        /bin/sleep 0.1
      done
      if idv_job_loaded "$service"; then
        print -u2 -- "IDV Login 系统任务尚未退出：$service；未继续清理。"
        return 1
      fi
    fi
  done
  if [[ -e "$IDV_JOB_PLIST" || -L "$IDV_JOB_PLIST" ]]; then
    [[ -f "$IDV_JOB_PLIST" && ! -L "$IDV_JOB_PLIST" && "$(/usr/bin/stat -f '%u' "$IDV_JOB_PLIST")" == 0 ]] || return 1
    /bin/rm -- "$IDV_JOB_PLIST"
  fi
}

idv_job_start() {
  local binary="$1" user_home="$2" user_name="$3" output="$4" staging
  [[ "$(/usr/bin/id -u)" == 0 ]] || return 1
  # The start lock lives beside the plist and is held by the caller. Only an
  # absent/stopped job reaches this path, so remove its old registration first.
  idv_job_remove || return 1
  /bin/mkdir -p "$IDV_JOB_DIR" || return 1
  [[ -d "$IDV_JOB_DIR" && ! -L "$IDV_JOB_DIR" && "$(/usr/bin/stat -f '%u' "$IDV_JOB_DIR")" == 0 ]] || return 1
  /bin/chmod 755 "$IDV_JOB_DIR" || return 1
  staging="$(/usr/bin/mktemp "$IDV_JOB_DIR/.idv-login.XXXXXX")" || return 1
  if ! idv_job_write_plist "$staging" "$binary" "$user_home" "$user_name" "$output"; then
    /bin/rm -f -- "$staging"
    return 1
  fi
  /usr/sbin/chown root:wheel "$staging" || return 1
  /bin/chmod 600 "$staging" || return 1
  /bin/mv -f -- "$staging" "$IDV_JOB_PLIST" || return 1
  /bin/launchctl bootstrap system "$IDV_JOB_PLIST"
}
