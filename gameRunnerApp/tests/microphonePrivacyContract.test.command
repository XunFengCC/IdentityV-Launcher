#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
if (( $# == 0 )); then
  plists=("$root/../playerLauncherApp/Info.plist" "$root/IdentityV-Mac.app/Contents/Info.plist")
  apps=()
elif (( $# == 1 )); then
  plists=("$1/Contents/Info.plist" "$1/Contents/Helpers/IdentityVGameRunner.app/Contents/Info.plist")
  apps=("$1" "$1/Contents/Helpers/IdentityVGameRunner.app")
else
  print -u2 -- "Usage: $0 [launcher.app]"
  exit 64
fi

# TCC attributes Wine microphone requests to the responsible GUI launcher.
# The runner also needs the declaration when launched independently.
/usr/bin/python3 - "${plists[@]}" <<'PY'
import plistlib
import sys
for path in sys.argv[1:]:
    with open(path, 'rb') as file:
        data = plistlib.load(file)
    purpose = data.get('NSMicrophoneUsageDescription')
    if not isinstance(purpose, str) or not purpose.strip():
        raise SystemExit(f'Missing microphone purpose in {path}')
print('Microphone privacy contract passed')
PY

# 用途说明只解决"TCC 能不能弹窗"；Hardened Runtime 下还要求**责任 App** 带
# com.apple.security.device.audio-input，否则 tccd 直接拒绝且不弹窗（2026-09-21 实测：
# 游戏没有音频输入，系统也不申请权限）。签名后的 bundle 才做这项断言。
(( ${#apps[@]} )) || exit 0
/usr/bin/python3 - "${apps[@]}" <<'PY'
import plistlib
import subprocess
import sys

missing = []
for app in sys.argv[1:]:
    proc = subprocess.run(
        ['/usr/bin/codesign', '-d', '--entitlements', ':-', app],
        capture_output=True)
    text = proc.stdout.decode('utf-8', 'replace').strip()
    actual = {}
    if text:
        actual = plistlib.loads(text.encode('utf-8'))
    if actual.get('com.apple.security.device.audio-input') is not True:
        missing.append(app)
if missing:
    raise SystemExit(
        'Missing com.apple.security.device.audio-input in: ' + ', '.join(missing))
print('Microphone entitlement contract passed')
PY
