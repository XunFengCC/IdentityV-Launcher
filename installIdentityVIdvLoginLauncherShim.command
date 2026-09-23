#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE="$PROJECT_ROOT/idvLoginLauncherApp/IdentityVIDVLoginLauncher"
APP_PATH="/Applications/第五人格 IDV Login.app"
DESTINATION="$APP_PATH/Contents/MacOS/IdentityVIDVLoginLauncher"
BACKUP_DIR="$HOME/Library/Application Support/IdentityVOnMac/migrationBackups"

[[ -f "$SOURCE" ]] || { /usr/bin/printf '缺少兼容启动器源文件：%s\n' "$SOURCE" >&2; exit 1; }
[[ "$(/usr/bin/id -u)" -ne 0 && "$HOME" == /Users/* ]] || { /usr/bin/printf '请从已登录的普通用户会话运行。\n' >&2; exit 1; }
[[ -d "$APP_PATH/Contents/MacOS" ]] || {
  /usr/bin/printf '未找到现有兼容启动 App：%s\n' "$APP_PATH" >&2
  exit 1
}

if [[ -f "$DESTINATION" ]] && ! /usr/bin/cmp -s "$SOURCE" "$DESTINATION"; then
  /bin/mkdir -p "$BACKUP_DIR"
  backup_path="$BACKUP_DIR/IdentityVIDVLoginLauncher-before-component-$(/bin/date '+%Y%m%d-%H%M%S')"
  /bin/cp -p "$DESTINATION" "$backup_path"
  /bin/chmod 600 "$backup_path"
fi

/bin/cp -p "$SOURCE" "$DESTINATION"
/bin/chmod 755 "$DESTINATION"
/usr/bin/codesign --force --deep --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/printf '已把旧 IDV Login App 收窄为组件启动兼容入口。\n'
