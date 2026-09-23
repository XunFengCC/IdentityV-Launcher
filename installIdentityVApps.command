#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
(( $# <= 1 )) || { print -u2 -- "用法：${0:t} [launcher|toolbox]"; exit 2; }
product="${1:-launcher}"
case "$product" in
  launcher)
    app_name="第五人格启动器"
    # Keep the builder's staging override so the tested candidate is installed.
    BUILD_ROOT="${IDENTITYV_BUILD_ROOT:-$PROJECT_ROOT/playerLauncherApp/build}"
    ;;
  toolbox)
    [[ -z "${IDENTITYV_BUILD_ROOT:-}" ]] || {
      print -u2 -- "工具箱构建器固定使用 maintenanceToolboxApp/build；请取消 IDENTITYV_BUILD_ROOT。"
      exit 64
    }
    app_name="第五人格工具箱"
    BUILD_ROOT="$PROJECT_ROOT/maintenanceToolboxApp/build"
    ;;
  *) print -u2 -- "用法：${0:t} [launcher|toolbox]"; exit 2 ;;
esac
[[ "$BUILD_ROOT" == /* ]] || { print -u2 -- 'IDENTITYV_BUILD_ROOT 必须是绝对路径。'; exit 64; }
SOURCE_APP="$BUILD_ROOT/$app_name.app"
DESTINATION_APP="/Applications/$app_name.app"
BACKUP_DIR="$HOME/Library/Application Support/IdentityVOnMac/migrationBackups"
STAGING_APP="/Applications/.$app_name.installing.$$"
BACKUP_APP=""
INSTALL_COMPLETE=0

cleanup() {
  if [[ -e "$STAGING_APP" ]]; then
    /bin/rm -rf -- "$STAGING_APP"
  fi
  if (( ! INSTALL_COMPLETE )) && [[ ! -e "$DESTINATION_APP" && -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
    /bin/mv -- "$BACKUP_APP" "$DESTINATION_APP" || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(/usr/bin/id -u)" -ne 0 ]] || {
  /usr/bin/printf '请在当前 macOS 用户会话中安装 %s，不要以 root 运行。\n' "$app_name" >&2
  exit 1
}

[[ -d "$SOURCE_APP" ]] || {
  /usr/bin/printf '缺少已构建的 %s：%s\n' "$app_name" "$SOURCE_APP" >&2
  exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
[[ ! -e "$STAGING_APP" ]] || {
  /usr/bin/printf '暂存路径已存在，拒绝覆盖：%s\n' "$STAGING_APP" >&2
  exit 1
}

/usr/bin/ditto "$SOURCE_APP" "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [[ -e "$DESTINATION_APP" ]]; then
  /bin/mkdir -p "$BACKUP_DIR"
  /bin/chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  BACKUP_APP="$BACKUP_DIR/$app_name-before-update-$(/bin/date '+%Y%m%d-%H%M%S').app"
  [[ ! -e "$BACKUP_APP" ]] || {
    /usr/bin/printf '备份目标已存在，拒绝覆盖：%s\n' "$BACKUP_APP" >&2
    exit 1
  }
  /bin/mv -- "$DESTINATION_APP" "$BACKUP_APP"
  /usr/bin/printf '旧 %s 已备份：%s\n' "$app_name" "$BACKUP_APP"
fi

/bin/mv -- "$STAGING_APP" "$DESTINATION_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"
INSTALL_COMPLETE=1
/usr/bin/printf '已安装 %s：%s\n' "$app_name" "$DESTINATION_APP"
