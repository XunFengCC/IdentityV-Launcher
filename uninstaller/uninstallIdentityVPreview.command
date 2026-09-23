#!/bin/zsh
# Alpha preview uninstaller.  It is deliberately closed over this manifest.
set -euo pipefail
MODE="preserve-game"
EXECUTE=false
REMOVE_LOGIN_DATA=false
ONLY_IDV_LOGIN=false
while (( $# )); do
  case "$1" in
    --preserve-game) MODE="preserve-game" ;;
    --remove-tool-data) MODE="remove-tool-data" ;;
    --remove-idv-login-data) REMOVE_LOGIN_DATA=true ;;
    --only-idv-login) ONLY_IDV_LOGIN=true ;;
    --execute) EXECUTE=true ;;
    --help) print '用法：uninstallIdentityVPreview.command [--preserve-game|--remove-tool-data] [--remove-idv-login-data] [--execute]'; exit 0 ;;
    *) print -u2 -- "未知参数：$1"; exit 2 ;;
  esac
  shift
done
[[ "$MODE" == "preserve-game" || "$MODE" == "remove-tool-data" ]] || exit 2
targets=(
  '/Applications/第五人格启动器.app'
  '/Applications/第五人格 Mac.app'
  '/Applications/第五人格 IDV Login.app'
  '/Applications/第五人格工具箱.app'
  '/Applications/第五人格性能浮窗.app'
  '/Library/PrivilegedHelperTools/identityv-on-mac'
  '/Library/Application Support/IdentityVOnMac/Components/idv-login'
  '/Library/Application Support/IdentityVOnMac/install-manifest.json'
  '/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json'
  '/Library/Logs/IdentityVOnMac'
  '/etc/sudoers.d/identityv-on-mac'
)
if [[ "$ONLY_IDV_LOGIN" == true ]]; then
  targets=(
    '/Library/PrivilegedHelperTools/identityv-on-mac'
    '/Library/Application Support/IdentityVOnMac/Components/idv-login'
    '/Library/Application Support/IdentityVOnMac/install-manifest.json'
    '/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json'
    '/Library/Logs/IdentityVOnMac/stop-idv-login.log'
    '/etc/sudoers.d/identityv-on-mac'
  )
fi
user_support="$HOME/Library/Application Support/IdentityVOnMac"
user_targets=(
  "$HOME/Library/Logs/IdentityVOnMac"
  "$HOME/Library/LaunchAgents/com.xunfeng.identityv.overlay.plist"
  "$user_support/Components"
  "$user_support/Diagnostics"
  "$user_support/Logs"
  "$user_support/Prefixes"
  "$user_support/install-work"
  "$user_support/repair-work"
  "$user_support/migrationBackups"
  "$user_support/Downloads"
  "$user_support/launcher.env"
  "$user_support/display-signature.sha256"
  "$user_support/display-signature-mainland.sha256"
  "$user_support/display-signature-global.sha256"
  "$user_support/runtime-binding.json"
  "$user_support/product-manager.lock"
)
if [[ "$MODE" == 'remove-tool-data' ]]; then
  user_targets+=(
    "$user_support/installation.json"
    "$user_support/products.json"
  )
fi
[[ "$REMOVE_LOGIN_DATA" == true ]] && user_targets+=("$HOME/Library/Application Support/idv-login")
print '第五人格启动器 Alpha 1 预览版卸载范围（不会删除游戏目录）：'
if [[ "$ONLY_IDV_LOGIN" == true ]]; then
  for p in "${targets[@]}"; do print -- "  $p"; done
else
  for p in "${targets[@]}" "${user_targets[@]}"; do print -- "  $p"; done
fi
print 'IDV Login 的账号/扫码/登录数据默认保留；游戏目录永不删除。'
print 'IDV Login 的按需系统任务及 /var/run/identityv-on-mac/idv-login.plist 由停止组件先撤销；不保留自动重启任务。'
print '默认内部游戏目录 IdentityVOnMac/Games 与外置 gameRoot 均不在删除列表中。'
print '共享 Wine/DXMT runtime 位于本工具专属的 Components 目录，会随兼容层一并移除；游戏文件仍保留。'
print '受管 hosts 行仅删除带 identityv-on-mac-compat 独占 tag 的精确行。'
print '系统根证书只会按 root-owned 项目台账中的精确 SHA-1/SHA-256 与保存 DER 核验后撤销；当前用户 PEM 仍存在时再追加一致性复验，旧安装无台账时不猜删。'
if [[ "$EXECUTE" != true ]]; then
  print '以上是 dry-run。需要实际执行时，以 root 调用并明确加 --execute。'
  exit 0
fi
[[ "$(/usr/bin/id -u)" -eq 0 ]] || { print -u2 '拒绝：实际卸载必须由已授权的 root 调用，本脚本不会自行弹密码框。'; exit 1; }
console_user="$(/usr/bin/stat -f '%Su' /dev/console)"
console_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')"
[[ "$console_user" != root && "$console_user" != loginwindow && "$console_home" == /Users/* && -d "$console_home" ]] || { print -u2 '拒绝：无法安全解析当前桌面用户 HOME。'; exit 1; }
console_uid="$(/usr/bin/dscl . -read "/Users/$console_user" UniqueID 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')"
[[ "$console_uid" == <-> && "$console_uid" -ge 500 ]] || { print -u2 '拒绝：当前桌面用户 UID 无效。'; exit 1; }
user_support="$console_home/Library/Application Support/IdentityVOnMac"
system_ca_manifest='/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json'
state_tool='/Library/PrivilegedHelperTools/identityv-on-mac/identityv-state-tool'
# A partial installation without its stop helper cannot safely promise that a
# loaded root job was removed. Preserve the remaining recovery tools instead
# of deleting their directory underneath a live service.
if [[ ! -x /Library/PrivilegedHelperTools/identityv-on-mac/stop-idv-login.sh ]] &&
   /bin/launchctl print system/com.xunfeng.identityv.idv-login >/dev/null 2>&1; then
  print -u2 'IDV Login 系统任务仍存在但停止组件缺失；请先修复组件再卸载。'
  exit 1
fi
# A ledger is an ownership capability, not merely an audit log.  If it exists,
# complete its exact certificate revocation before deleting the helper that can
# perform the validation.  Old installs without a ledger deliberately remain a
# no-op for System.keychain rather than guessing from the shared certificate
# display name.
if [[ -e "$system_ca_manifest" ]]; then
  [[ -x "$state_tool" ]] || { print -u2 '检测到系统 CA 台账但状态工具缺失；拒绝继续卸载以免遗留未知系统信任。'; exit 1; }
  "$state_tool" remove-idv-login-ca --home "$console_home"
fi
if [[ "$ONLY_IDV_LOGIN" == true ]]; then
  # Stop only our root-owned proxy and remove its exact host mappings. The
  # launcher, games, prefixes, runtime and the user's idv-login account data
  # intentionally remain untouched.
  if [[ -x /Library/PrivilegedHelperTools/identityv-on-mac/stop-idv-login.sh ]]; then
    /Library/PrivilegedHelperTools/identityv-on-mac/stop-idv-login.sh
  fi
  for p in "${targets[@]}"; do
    case "$p" in \
      /Library/PrivilegedHelperTools/identityv-on-mac|\
      '/Library/Application Support/IdentityVOnMac/Components/idv-login'|\
      '/Library/Application Support/IdentityVOnMac/install-manifest.json'|\
      '/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json'|\
      '/Library/Logs/IdentityVOnMac/stop-idv-login.log'|\
      /etc/sudoers.d/identityv-on-mac) /bin/rm -rf -- "$p" ;;
      *) print -u2 '拒绝未知 IDV Login 系统路径'; exit 1 ;;
    esac
  done
  # Remove only parents that became empty. Existing runtime, logs or any
  # unrelated item prevents rmdir and remains untouched.
  /bin/rmdir '/Library/Application Support/IdentityVOnMac/Components' >/dev/null 2>&1 || true
  /bin/rmdir '/Library/Application Support/IdentityVOnMac' >/dev/null 2>&1 || true
  /bin/rmdir '/Library/Logs/IdentityVOnMac' >/dev/null 2>&1 || true
  print '已卸载 IDV Login 组件；游戏、兼容环境、启动器和默认登录数据均保留。'
  exit 0
fi
user_targets=(
  "$console_home/Library/Logs/IdentityVOnMac"
  "$console_home/Library/LaunchAgents/com.xunfeng.identityv.overlay.plist"
  "$user_support/Components"
  "$user_support/Diagnostics"
  "$user_support/Logs"
  "$user_support/Prefixes"
  "$user_support/install-work"
  "$user_support/repair-work"
  "$user_support/migrationBackups"
  "$user_support/Downloads"
  "$user_support/launcher.env"
  "$user_support/display-signature.sha256"
  "$user_support/display-signature-mainland.sha256"
  "$user_support/display-signature-global.sha256"
  "$user_support/runtime-binding.json"
  "$user_support/product-manager.lock"
)
if [[ "$MODE" == 'remove-tool-data' ]]; then
  user_targets+=("$user_support/installation.json" "$user_support/products.json")
fi
[[ "$REMOVE_LOGIN_DATA" == true ]] && user_targets+=("$console_home/Library/Application Support/idv-login")
# Stop the exact user LaunchAgent before deleting its plist. Failure is fine if
# it was never installed or is already stopped.
if [[ -f "$console_home/Library/LaunchAgents/com.xunfeng.identityv.overlay.plist" ]]; then
  /bin/launchctl bootout "gui/$console_uid" "$console_home/Library/LaunchAgents/com.xunfeng.identityv.overlay.plist" >/dev/null 2>&1 || true
fi
# Stop helper is owned by our fixed directory; it also performs exact hosts cleanup.
if [[ -x /Library/PrivilegedHelperTools/identityv-on-mac/stop-idv-login.sh ]]; then
  /Library/PrivilegedHelperTools/identityv-on-mac/stop-idv-login.sh
fi
for p in "${targets[@]}"; do
  case "$p" in '/Applications/第五人格启动器.app'|'/Applications/第五人格 Mac.app'|'/Applications/第五人格 IDV Login.app'|'/Applications/第五人格工具箱.app'|'/Applications/第五人格性能浮窗.app'|/Library/PrivilegedHelperTools/identityv-on-mac|'/Library/Application Support/IdentityVOnMac/Components/idv-login'|'/Library/Application Support/IdentityVOnMac/install-manifest.json'|'/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json'|'/Library/Logs/IdentityVOnMac'|/etc/sudoers.d/identityv-on-mac) /bin/rm -rf -- "$p" ;; *) print -u2 '拒绝未知系统路径'; exit 1;; esac
done
for p in "${user_targets[@]}"; do
  case "$p" in \
    "$console_home/Library/Logs/IdentityVOnMac"|\
    "$console_home/Library/LaunchAgents/com.xunfeng.identityv.overlay.plist"|\
    "$user_support/Components"|"$user_support/Diagnostics"|"$user_support/Logs"|\
    "$user_support/Prefixes"|"$user_support/install-work"|"$user_support/repair-work"|\
    "$user_support/migrationBackups"|"$user_support/Downloads"|"$user_support/launcher.env"|\
    "$user_support/display-signature.sha256"|"$user_support/display-signature-mainland.sha256"|\
    "$user_support/display-signature-global.sha256"|"$user_support/runtime-binding.json"|\
    "$user_support/product-manager.lock"|\
    "$user_support/installation.json"|"$user_support/products.json"|\
    "$console_home/Library/Application Support/idv-login") /bin/rm -rf -- "$p" ;;
    *) print -u2 '拒绝未知用户路径'; exit 1;;
  esac
done
# Remove only now-empty system parents. Any unrelated or future component
# keeps the directory non-empty and makes these operations harmless no-ops.
/bin/rmdir '/Library/Application Support/IdentityVOnMac/Components' >/dev/null 2>&1 || true
/bin/rmdir '/Library/Application Support/IdentityVOnMac' >/dev/null 2>&1 || true
/bin/rmdir '/Library/Logs/IdentityVOnMac' >/dev/null 2>&1 || true
# Only remove now-empty parents. `Games/` or any other retained item keeps the
# support directory in place and makes accidental game deletion impossible.
/bin/rmdir "$user_support" >/dev/null 2>&1 || true
print '已撤销项目 App、helper、sudoers、精确受管 hosts 行、LaunchAgent 和所选工具数据；游戏目录未删除。'
