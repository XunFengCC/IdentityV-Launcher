#!/bin/zsh
# Keep product build, candidate run and installed-app replacement distinct. The
# old `fast` path only built the keyboard dylib but then installed a stale App.
set -euo pipefail
PROJECT_ROOT="${0:A:h}"
SCRIPT_NAME="${0:t}"

usage() {
  print -- "用法：$SCRIPT_NAME [launcher|toolbox|keyboard] [build|run|install]"
  print -- "  launcher  构建第五人格启动器（旧 full）"
  print -- "  toolbox   构建维护者诊断工具箱"
  print -- "  keyboard  只构建键盘组件（旧 fast；不能单独运行或安装 App）"
  print -- "  build     只生成候选；run 打开候选；install 构建后更新 /Applications 并保留旧版备份"
}

(( $# <= 2 )) || { usage >&2; exit 2; }
product="${1:-launcher}"
action="${2:-build}"
case "$product" in
  launcher|full) product=launcher ;;
  toolbox) ;;
  keyboard|fast) product=keyboard ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
case "$action" in
  build|run|install) ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$product" == keyboard ]]; then
  [[ "$action" == build ]] || { print -u2 -- "键盘组件不是独立 App；请先构建完整启动器。"; exit 2; }
  "$PROJECT_ROOT/buildIdentityVCommandGraveForwarder.command"
  exit
fi

if [[ "$product" == launcher ]]; then
  "$PROJECT_ROOT/buildPlayerLauncher.command"
  build_root="${IDENTITYV_BUILD_ROOT:-$PROJECT_ROOT/playerLauncherApp/build}"
  candidate="$build_root/第五人格启动器.app"
else
  [[ -z "${IDENTITYV_BUILD_ROOT:-}" ]] || {
    print -u2 -- "工具箱构建器固定使用 maintenanceToolboxApp/build；请取消 IDENTITYV_BUILD_ROOT，避免读错候选。"
    exit 64
  }
  "$PROJECT_ROOT/buildMaintenanceToolbox.command"
  candidate="$PROJECT_ROOT/maintenanceToolboxApp/build/第五人格工具箱.app"
fi

case "$action" in
  build) print -- "候选已构建：$candidate" ;;
  run) /usr/bin/open -n "$candidate" ;;
  install) "$PROJECT_ROOT/installIdentityVApps.command" "$product" ;;
esac
