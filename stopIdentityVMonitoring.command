#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
OVERLAY_LABEL="com.identityvonmac.overlay"
LEGACY_OVERLAY_LABEL="com.xunfeng.identityv.overlay"
USER_ID="$(/usr/bin/id -u)"
PLIST_DIR="${HOME}/Library/LaunchAgents"

if [[ -x "$SCRIPT_DIR/captureIdentityVPrelaunchStream.command" ]]; then
  "$SCRIPT_DIR/captureIdentityVPrelaunchStream.command" --stop >/dev/null 2>&1 || true
fi

for label in "$OVERLAY_LABEL" "$LEGACY_OVERLAY_LABEL"; do
  plist="$PLIST_DIR/$label.plist"
  /bin/launchctl bootout "gui/$USER_ID/$label" >/dev/null 2>&1 || true
  [[ -f "$plist" ]] && /bin/launchctl bootout "gui/$USER_ID" "$plist" >/dev/null 2>&1 || true
done

# Only terminate this product's named monitor process.  Do not rely on a
# development checkout path, and do not match arbitrary Python processes.
/usr/bin/pkill -u "$USER_ID" -f 'identityv_overlay_server[.]py' >/dev/null 2>&1 || true

# The native always-on-top window is a separate app, not a LaunchAgent child.
# Ask it to quit first, then bound the wait so a hidden panel cannot linger.
/usr/bin/osascript -e 'tell application id "com.xunfeng.identityv.monitor-overlay" to quit' >/dev/null 2>&1 || true
/usr/bin/pkill -u "$USER_ID" -TERM -f '/Applications/第五人格性能浮窗[.]app/Contents/MacOS/IdentityVMonitorOverlay' >/dev/null 2>&1 || true
for _ in {1..20}; do
  /usr/bin/pgrep -f '/Applications/第五人格性能浮窗[.]app/Contents/MacOS/IdentityVMonitorOverlay' >/dev/null 2>&1 || break
  sleep 0.1
done
/usr/bin/pkill -u "$USER_ID" -KILL -f '/Applications/第五人格性能浮窗[.]app/Contents/MacOS/IdentityVMonitorOverlay' >/dev/null 2>&1 || true

echo "已停止第五人格性能采集、服务与浮窗。"
