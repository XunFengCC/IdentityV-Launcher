#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
script="$root/uninstaller/uninstallIdentityVPreview.command"
state_tool="$root/privilegedHelpers/IdentityVPrivilegedStateTool.swift"
out="$(/bin/zsh "$script" --remove-tool-data)"
[[ "$out" == *'dry-run'* ]]
[[ "$out" == *'/etc/sudoers.d/identityv-on-mac'* ]]
[[ "$out" == *'游戏目录'* ]]
login_out="$(/bin/zsh "$script" --only-idv-login)"
[[ "$login_out" == *'/Library/Logs/IdentityVOnMac/stop-idv-login.log'* ]]
[[ "$login_out" == *'/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json'* ]]
[[ "$login_out" == *'当前用户 PEM 仍存在时再追加一致性复验'* ]]
[[ "$login_out" != *'/Applications/第五人格启动器.app'* ]]
[[ "$login_out" != *'/Library/Logs/IdentityVOnMac\n'* ]]
! /bin/zsh "$script" --execute >/dev/null 2>&1
/usr/bin/grep -Fq 'remove-idv-login-ca --home "$console_home"' "$script"
/usr/bin/grep -Fq 'idv-login-system-ca.json' "$script"
/usr/bin/grep -Fq 'recorded-sha1-with-root-ledger-and-exact-system-der-hash-verification' "$root/installIdentityVPasswordlessHelpers.command"
/usr/bin/grep -Fq 'find-certificate", "-a", "-c", "Netease Login Helper CA", "-p"' "$state_tool"
/usr/bin/grep -Fq '多个同名证书的精确删除计划失败' "$state_tool"
/usr/bin/grep -Fq '任意用户 PEM 冒充反例未被拒绝' "$state_tool"
/usr/bin/grep -Fq '已不存在证书的台账清理计划失败' "$state_tool"
/usr/bin/grep -Fq '多 CA 台账追加/精确撤销反例失败' "$state_tool"
print '卸载器 dry-run 与 fail-closed 测试通过。'
