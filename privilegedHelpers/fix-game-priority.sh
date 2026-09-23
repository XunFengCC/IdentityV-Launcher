#!/bin/zsh
set -euo pipefail

# The former helper selected processes through global command-line regexes.
# That cannot establish game-prefix ancestry safely, so Alpha deliberately does
# not expose it through sudoers or the start path. Keep a clear fail-closed
# stub to make stale installations harmless until a per-prefix verifier exists.
/usr/bin/printf '预览版未启用特权优先级修正：缺少可验证的游戏前缀进程归属。\n' >&2
exit 64
