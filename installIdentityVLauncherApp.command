#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE_APP="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app"
DESTINATION_APP="/Applications/第五人格 Mac.app"
BACKUP_DIR="$HOME/Library/Application Support/IdentityVOnMac/migrationBackups"
STAGING_APP="/Applications/.第五人格 Mac.installing.$$"
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
  print -u2 -- "请在当前 macOS 用户会话中安装，不要以 root 运行。"
  exit 1
}
[[ -d "$SOURCE_APP" ]] || {
  print -u2 -- "缺少项目候选 App：$SOURCE_APP"
  exit 1
}
[[ ! -e "$STAGING_APP" ]] || {
  print -u2 -- "暂存路径已存在，拒绝覆盖：$STAGING_APP"
  exit 1
}

current_uid="$(/usr/bin/id -u)"
if /usr/bin/pgrep -u "$current_uid" -f 'C:\\Games\\IdentityV\\dwrg[.]exe.*--start_from_launcher=1' >/dev/null 2>&1; then
  print -u2 -- "第五人格仍在运行；请先用快速重启组件收束旧游戏会话。"
  exit 2
fi
if /usr/bin/pgrep -u "$current_uid" -f '/Applications/第五人格 Mac[.]app/Contents/MacOS/launchIdentityVRunner --run' >/dev/null 2>&1; then
  print -u2 -- "旧版第五人格 runner 仍在退出；稍后重试安装。"
  exit 2
fi

[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$SOURCE_APP/Contents/Info.plist" 2>/dev/null)" == "com.xunfeng.identityv.mac" ]] || {
  print -u2 -- "候选 App 的 Bundle ID 不符合预期。"
  exit 1
}
[[ -x "$SOURCE_APP/Contents/MacOS/launchIdentityV" ]] || {
  print -u2 -- "候选 App 缺少原生启动入口。"
  exit 1
}
[[ -x "$SOURCE_APP/Contents/MacOS/launchIdentityVRunner" ]] || {
  print -u2 -- "候选 App 缺少 runner。"
  exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"

/usr/bin/ditto "$SOURCE_APP" "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

if [[ -e "$DESTINATION_APP" ]]; then
  /bin/mkdir -p "$BACKUP_DIR"
  /bin/chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  BACKUP_APP="$BACKUP_DIR/第五人格 Mac-before-default-input-$(/bin/date '+%Y%m%d-%H%M%S').app"
  [[ ! -e "$BACKUP_APP" ]] || {
    print -u2 -- "备份目标已存在，拒绝覆盖：$BACKUP_APP"
    exit 1
  }
  /bin/mv -- "$DESTINATION_APP" "$BACKUP_APP"
  print -r -- "旧启动器备份：$BACKUP_APP"
fi

/bin/mv -- "$STAGING_APP" "$DESTINATION_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"
INSTALL_COMPLETE=1
print -r -- "已安装第五人格 Mac 启动器：$DESTINATION_APP"
