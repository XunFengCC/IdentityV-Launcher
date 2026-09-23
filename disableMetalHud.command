#!/bin/zsh
set -euo pipefail

CONFIG_DIR="$HOME/Library/Application Support/IdentityVOnMac"
MAINTENANCE_DIR="$CONFIG_DIR/Maintenance"
CONFIG_FILE="$MAINTENANCE_DIR/metal-hud.env"

safe_private_directory() {
  local owner mode
  [[ -d "$1" && ! -L "$1" ]] || return 1
  owner="$(/usr/bin/stat -f '%u' "$1" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -f '%Lp' "$1" 2>/dev/null || true)"
  [[ "$owner" == "$(id -u)" && "$mode" == <-> ]] || return 1
  (( (8#$mode & 8#077) == 0 && (8#$mode & 8#700) == 8#700 )) && [[ "$mode" == 700 ]]
}

[[ ! -L "$CONFIG_DIR" && ! -L "$MAINTENANCE_DIR" ]] || { print -u2 -r -- "拒绝写入符号链接配置目录。"; exit 1; }
/bin/mkdir -p "$MAINTENANCE_DIR"
/bin/chmod 700 "$CONFIG_DIR" "$MAINTENANCE_DIR"
safe_private_directory "$CONFIG_DIR" && safe_private_directory "$MAINTENANCE_DIR" || {
  print -u2 -r -- "Metal HUD 配置目录的归属或权限不安全。"; exit 1; }
temp="$(/usr/bin/mktemp "$MAINTENANCE_DIR/.metal-hud.XXXXXX")"
/bin/chmod 600 "$temp"
print -r -- $'schema=1\nenabled=0' >| "$temp"
/bin/mv -f "$temp" "$CONFIG_FILE"

echo "Metal HUD 已关闭。重新启动第五人格后生效。"
if [[ "${IDV_TOOLBOX_NONINTERACTIVE:-0}" != "1" ]]; then
  read -r "?按回车关闭此窗口..."
fi
