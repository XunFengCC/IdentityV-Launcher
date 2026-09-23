#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MANAGER="$SCRIPT_DIR/IdentityVProductManager"

if [[ ! -x "$MANAGER" ]]; then
  print -u2 -- "启动器组件不完整：缺少 IdentityVProductManager。请重新安装启动器。"
  exit 70
fi

exec "$MANAGER" "$@"
