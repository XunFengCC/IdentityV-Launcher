#!/bin/zsh
# Reports and, if needed, restores the Mac function-key row (F1-F12).
#
# Why this exists: while the game is frontmost the launcher temporarily raises
# the session-wide HIDFKeyMode so the F row reaches the game as F1-F12.  That
# switch is shared by the whole keyboard, so if a session ends without restoring
# it — the 2026-09-18 failure — brightness/volume/playback keys stop working
# outside the game.  The launcher now adopts any stranded standard row and
# releases it whenever the game is not frontmost; this command is the manual
# escape hatch for when no watcher is alive.
#
# It never starts or stops the game.  Rationale and evidence:
# projects/identityVOnMac/functionKeyController/README.md

set -u

CONFIG_DIR="$HOME/Library/Application Support/IdentityVOnMac"
STATE_FILE="$CONFIG_DIR/function-keys.session.json"
INSTALLED_CONTROLLER="/Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app/Contents/Resources/IdentityVFunctionKeyController"
PROJECT_CONTROLLER="${0:A:h}/functionKeyController/build/IdentityVFunctionKeyController"

controller() {
  if [[ -x "$INSTALLED_CONTROLLER" ]]; then
    print -r -- "$INSTALLED_CONTROLLER"
  else
    print -r -- "$PROJECT_CONTROLLER"
  fi
}

mode_now() {
  local out
  out="$("$(controller)" --status 2>/dev/null || true)"
  print -r -- "${out//[^0-9]/}"
}

game_pid() { /usr/bin/pgrep -f 'dwrg\.exe' | /usr/bin/head -1 }

game_frontmost() {
  local front
  front="$(/usr/bin/lsappinfo info -only pid "$(/usr/bin/lsappinfo front 2>/dev/null)" 2>/dev/null |
    /usr/bin/grep -o 'pid = [0-9]*' | /usr/bin/grep -o '[0-9]*')"
  [[ -n "$front" && -n "$(game_pid)" && "$front" == "$(game_pid)" ]]
}

print -- "当前 F 排模式：HIDFKeyMode=$(mode_now)（1=标准功能键，0=亮度/音量媒体键）"
if game_frontmost; then
  print -- "游戏在前台：现在的标准功能键是预期的，切出游戏会自动恢复媒体键。"
else
  print -- "游戏不在前台：模式应为 0。"
fi
[[ -e "$STATE_FILE" ]] && print -- "存在未恢复记录：$STATE_FILE" || print -- "没有未恢复记录（正常）"

case "${1:-}" in
  --restore)
    "$(controller)" --force-media-row --game-pid "$(game_pid || print -r -- 0)"
    if [[ "$(mode_now)" == "1" && -e "$STATE_FILE" ]]; then
      print -- "仍为 1：清除遗留记录后重试。"
      /bin/rm -f "$STATE_FILE" 2>/dev/null || true
      "$(controller)" --force-media-row --game-pid "$(game_pid || print -r -- 0)"
    fi
    print -- "恢复后模式：HIDFKeyMode=$(mode_now)"
    ;;
  ""|--status)
    if [[ "$(mode_now)" == "1" ]] && ! game_frontmost; then
      print -- "亮度/音量键失效时运行：$0 --restore"
    fi
    ;;
  *)
    print -u2 -- "用法：${0:t} [--status|--restore]"
    exit 2
    ;;
esac
