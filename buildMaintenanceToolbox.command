#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE_ROOT="$PROJECT_ROOT/maintenanceToolboxApp"
BUILD_ROOT="$SOURCE_ROOT/build"
APP_PATH="$BUILD_ROOT/第五人格工具箱.app"
CONTENTS="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
EXECUTABLE="$MACOS_DIR/IdentityVMonitor"
DISPLAY_HELPER="$MACOS_DIR/IdentityVOverlayDisplay"
SAMPLER_SOURCE="$PROJECT_ROOT/denseMetrics/idv-dense-metrics"
SAMPLER_DESTINATION="$RESOURCES_DIR/idv-dense-metrics"
DENSE_SOURCE="$PROJECT_ROOT/sharedDiagnostics/DenseMonitoring.swift"
OVERLAY_SOURCE="$SOURCE_ROOT/Sources/PerformanceOverlay.swift"
FREEZE_STACK_SOURCE="$SOURCE_ROOT/Sources/FreezeStackCapture.swift"
HEALTH_SOURCE="$PROJECT_ROOT/sharedDiagnostics/GameHealth.swift"
RESOURCE_SOURCE="$PROJECT_ROOT/sharedDiagnostics/ResourceSampling.swift"
PROTOCOL_SOURCE="$SOURCE_ROOT/Sources/OverlayProtocol.swift"
DISPLAY_HELPER_SOURCE="$SOURCE_ROOT/Sources/IdentityVOverlayDisplay.swift"
ICON_SOURCE="$SOURCE_ROOT/Assets/IdentityVToolbox.icns"
ICON_DESTINATION="$RESOURCES_DIR/IdentityVToolbox.icns"
SELF_TEST="$BUILD_ROOT/MonitorProcessSelfTest"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

# 代码签名身份（原因、优先级与边界见 signing/lib/signIdentityV.sh）：
# 默认 auto——有 Developer ID Application 就用它并带 Hardened Runtime/时间戳，
# 否则沿用本地开发身份，再否则 ad-hoc。身份解析失败时 fail closed，不静默退回。
source "$PROJECT_ROOT/signing/lib/signIdentityV.sh"
identityv_resolve_identity

[[ -f "$DENSE_SOURCE" ]] || { print -u2 -- "缺少已验证的高密度采集 ownership 控制器。"; exit 1; }
[[ -f "$OVERLAY_SOURCE" ]] || { print -u2 -- "缺少进程内性能浮窗与画面采集器。"; exit 1; }
[[ -f "$FREEZE_STACK_SOURCE" ]] || { print -u2 -- "缺少联合采集冻结栈捕获器。"; exit 1; }
[[ -f "$DISPLAY_HELPER_SOURCE" ]] || { print -u2 -- "缺少跨全屏 Space 的仅显示性能浮窗辅助进程。"; exit 1; }
[[ -f "$ICON_SOURCE" ]] || { print -u2 -- "缺少第五人格工具箱图标 IdentityVToolbox.icns。"; exit 1; }
"$PROJECT_ROOT/denseMetrics/build.command"
python3 "$PROJECT_ROOT/denseMetrics/testLifecycle.py"
[[ -x "$SAMPLER_SOURCE" ]] || { print -u2 -- "缺少高密度采集器。"; exit 1; }

/bin/rm -rf "$APP_PATH" "$SELF_TEST"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

/usr/bin/xcrun swiftc \
  -swift-version 5 -warnings-as-errors -O -parse-as-library \
  -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework IOKit \
  "$SOURCE_ROOT/Sources/IdentityVMonitorApp.swift" \
  "$OVERLAY_SOURCE" \
  "$FREEZE_STACK_SOURCE" \
  "$HEALTH_SOURCE" "$RESOURCE_SOURCE" "$PROTOCOL_SOURCE" \
  "$DENSE_SOURCE" \
  -o "$EXECUTABLE"
/usr/bin/xcrun swiftc \
  -swift-version 5 -warnings-as-errors -O -parse-as-library \
  -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -framework AppKit \
  "$DISPLAY_HELPER_SOURCE" \
  "$PROTOCOL_SOURCE" \
  -o "$DISPLAY_HELPER"
/bin/cp "$SOURCE_ROOT/Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$SAMPLER_SOURCE" "$SAMPLER_DESTINATION"
/bin/cp "$ICON_SOURCE" "$ICON_DESTINATION"
/bin/chmod 755 "$EXECUTABLE" "$DISPLAY_HELPER" "$SAMPLER_DESTINATION"
/bin/chmod 644 "$ICON_DESTINATION"
# 先给两个辅助可执行文件指定稳定 identifier，再由内到外签整个工具箱 bundle。
# 之前的 `--deep --sign -` 只把外层选项套一遍，且内层代码全部是 ad-hoc，无法公证。
identityv_codesign "$SAMPLER_DESTINATION" --identifier com.xunfeng.identityv.monitor.sampler
identityv_codesign "$DISPLAY_HELPER" --identifier com.xunfeng.identityv.monitor.display
identityv_sign_bundle_tree "$APP_PATH"

/usr/bin/plutil -lint "$CONTENTS/Info.plist"
identityv_verify_bundle_tree "$APP_PATH"
/usr/bin/file "$EXECUTABLE" | /usr/bin/grep -q 'arm64'
/usr/bin/file "$DISPLAY_HELPER" | /usr/bin/grep -q 'arm64'
"$PROJECT_ROOT/runtimeManifest/auditMachODeploymentTargets.command" "$APP_PATH"
"$DISPLAY_HELPER" --self-test

/usr/bin/xcrun swiftc \
  -swift-version 5 -warnings-as-errors -O -parse-as-library \
  -D MONITOR_PROCESS_SELF_TEST -D TOOLBOX_PROCESS_SELF_TEST \
  -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework IOKit \
  "$SOURCE_ROOT/Sources/IdentityVMonitorApp.swift" \
  "$OVERLAY_SOURCE" \
  "$FREEZE_STACK_SOURCE" \
  "$HEALTH_SOURCE" "$RESOURCE_SOURCE" "$PROTOCOL_SOURCE" \
  "$SOURCE_ROOT/Sources/MonitorProcessSelfTest.swift" \
  "$DENSE_SOURCE" \
  -o "$SELF_TEST"
"$SELF_TEST"
if [[ "${IDENTITYV_MONITOR_LIVE_PROBE:-0}" == 1 ]]; then
  "$SELF_TEST" --live-resource-probe
fi
/bin/rm -f "$SELF_TEST"

legacy_overlay_path="/Applications/第五人格性能浮窗"".app"
legacy_overlay_id="com.xunfeng.identityv.monitor""-overlay"
if rg -n --fixed-strings "$legacy_overlay_path" "$SOURCE_ROOT"; then
  print -u2 -- "工具箱仍引用旧性能浮窗 App 路径。"
  exit 1
fi
if rg -n --fixed-strings "$legacy_overlay_id" "$SOURCE_ROOT"; then
  print -u2 -- "工具箱仍引用旧性能浮窗 bundle identifier。"
  exit 1
fi

print -- "构建完成：$APP_PATH"
