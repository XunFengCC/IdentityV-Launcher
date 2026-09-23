#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
SOURCE_ROOT="$PROJECT_ROOT/playerLauncherApp"
BUILD_ROOT="${IDENTITYV_BUILD_ROOT:-$SOURCE_ROOT/build}"
[[ "$BUILD_ROOT" == /* ]] || { print -u2 -- "IDENTITYV_BUILD_ROOT 必须是绝对路径。"; exit 64; }
APP_PATH="$BUILD_ROOT/第五人格启动器.app"
CONTENTS="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
HELPERS_DIR="$CONTENTS/Helpers"
EXECUTABLE="$MACOS_DIR/IdentityVLauncher"
PROMPT_HELPER="$MACOS_DIR/IdentityVHangPrompt"
PROMPT_PROTOCOL="$SOURCE_ROOT/Sources/LauncherHangPromptProtocol.swift"
PROMPT_CLIENT="$SOURCE_ROOT/Sources/LauncherHangPromptClient.swift"
RUNNER_SOURCE_APP="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app"
RUNNER_DESTINATION_APP="$HELPERS_DIR/IdentityVGameRunner.app"
RESTART_SOURCE="$PROJECT_ROOT/restartIdentityVGame.command"
RESTART_DESTINATION="$RESOURCES_DIR/restartIdentityVGame.command"
STOP_LOGIN_SOURCE="$PROJECT_ROOT/stopIdentityVIdvLogin.command"
STOP_LOGIN_DESTINATION="$RESOURCES_DIR/stopIdentityVIdvLogin.command"
ROUTE_SOURCE="$SOURCE_ROOT/Resources/currentRoute.md"
ROUTE_DESTINATION="$RESOURCES_DIR/currentRoute.md"
PRODUCT_MANAGER_SOURCE="$PROJECT_ROOT/productManager/IdentityVProductManager.swift"
PRODUCT_MANAGER_WRAPPER="$PROJECT_ROOT/productManager/identityVProductManager.command"
PRODUCT_CATALOG="$PROJECT_ROOT/productCatalog/products.json"
PRODUCT_MANAGER_DESTINATION="$RESOURCES_DIR/IdentityVProductManager"
PRODUCT_MANAGER_WRAPPER_DESTINATION="$RESOURCES_DIR/identityVProductManager.command"
PRODUCT_CATALOG_DESTINATION="$RESOURCES_DIR/products.json"
DOWNLOAD_SUPERVISOR_ROOT="$PROJECT_ROOT/gameDownloader"
DOWNLOAD_SUPERVISOR_DESTINATION="$RESOURCES_DIR/IdentityVDownloadSupervisor"
MANIFEST_PLANNER_ROOT="$PROJECT_ROOT/manifestPlanner"
MANIFEST_PLANNER_DESTINATION="$RESOURCES_DIR/IdentityVManifestPlanner"
CORE_BOOTSTRAP_ROOT="$PROJECT_ROOT/downloaderCoreBootstrap"
CORE_BOOTSTRAP_DESTINATION="$RESOURCES_DIR/IdentityVDownloaderCoreBootstrap"
GLOBAL_ADAPTER_ROOT="$PROJECT_ROOT/globalAdapter"
GLOBAL_ADAPTER_DESTINATION="$RESOURCES_DIR/IdentityVGlobalAdapter"
RUNTIME_BOOTSTRAP_ROOT="$PROJECT_ROOT/runtimeBootstrap"
RUNTIME_BOOTSTRAP_DESTINATION="$RESOURCES_DIR/IdentityVRuntimeBootstrap"
RUNTIME_BOOTSTRAP_MANIFEST_SOURCE="$RUNTIME_BOOTSTRAP_ROOT/runtime-manifest.json"
RUNTIME_BOOTSTRAP_MANIFEST_DESTINATION="$RESOURCES_DIR/runtime-manifest.json"
RUNTIME_PATCH_ROOT="$RUNTIME_BOOTSTRAP_ROOT/releasePayloads"
RUNTIME_PATCH_DESTINATION="$RESOURCES_DIR/RuntimePatches"
RUNTIME_PATCH_AUDIT="$RUNTIME_BOOTSTRAP_ROOT/verifyRuntimePatchPayloads.command"
RUNTIME_CATALOG_SOURCE="$PROJECT_ROOT/runtimeManifest/runtime-catalog.json"
RUNTIME_CATALOG_DESTINATION="$RESOURCES_DIR/runtime-catalog.json"
CORE_COMPONENT_MANIFEST_SOURCE="$PROJECT_ROOT/downloaderCoreComponent.json"
CORE_COMPONENT_MANIFEST_DESTINATION="$RESOURCES_DIR/downloaderCoreComponent.json"
IDV_LOGIN_COMPONENT_MANIFEST_SOURCE="$PROJECT_ROOT/idvLoginComponent.json"
IDV_LOGIN_COMPONENT_MANIFEST_DESTINATION="$RESOURCES_DIR/idvLoginComponent.json"
IDV_LOGIN_DOWNLOADER_ROOT="$PROJECT_ROOT/idvLoginComponent/downloader"
IDV_LOGIN_DOWNLOADER_DESTINATION="$RESOURCES_DIR/IdentityVIdvLoginDownloader"
IDV_LOGIN_INSTALLER_SOURCE="$PROJECT_ROOT/installIdentityVPasswordlessHelpers.command"
IDV_LOGIN_PAYLOAD_DESTINATION="$RESOURCES_DIR/InstallerPayload"
DIAGNOSTIC_EXPORTER_SOURCE="$PROJECT_ROOT/diagnostics/IdentityVDiagnosticExporter.swift"
DIAGNOSTIC_EXPORTER_DESTINATION="$RESOURCES_DIR/IdentityVDiagnosticExporter"
THIRD_PARTY_DIR="$RESOURCES_DIR/ThirdParty"
HEALTH_SOURCE="$PROJECT_ROOT/sharedDiagnostics/GameHealth.swift"
RESOURCE_SOURCE="$PROJECT_ROOT/sharedDiagnostics/ResourceSampling.swift"
DENSE_SOURCE="$PROJECT_ROOT/sharedDiagnostics/DenseMonitoring.swift"
ENV_SELF_CHECK="$BUILD_ROOT/LauncherEnvironmentSelfTest"
PROCESS_SELF_CHECK="$BUILD_ROOT/RuntimeProcessMatcherSelfTest"
INSTALL_ATTEMPT_LOG_SELF_CHECK="$BUILD_ROOT/InstallAttemptLogSelfTest"
LAUNCH_LOCATION_SELF_CHECK="$BUILD_ROOT/LaunchLocationSelfTest"
LAUNCHER_HANG_SELF_CHECK="$BUILD_ROOT/LauncherHangSelfTest"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
GO_BIN="$(/usr/bin/which go 2>/dev/null || true)"
# 代码签名身份：原因、优先级与边界见 signing/lib/signIdentityV.sh。
# 默认 auto——有 Developer ID Application 就用它（带 Hardened Runtime 与安全时间戳），
# 否则沿用本地开发身份引用，再否则 ad-hoc；身份存在但不可用时 fail closed，不再
# 静默退回 ad-hoc cdhash（那会让麦克风授权在每次重建后失效）。
source "$PROJECT_ROOT/signing/lib/signIdentityV.sh"
identityv_resolve_identity

# Never rebuild a bundle underneath a live development instance.  macOS keeps
# the executable mapped, but resources disappear as soon as the bundle is
# replaced, which can make a half-old UI report missing helpers.  Release
# packaging uses its own stage and is unaffected by this development guard.
RUNNING_LAUNCHER_PID="$(/bin/ps -axo pid=,command= | /usr/bin/python3 -c '
import sys
target = sys.argv[1]
found = None
for line in sys.stdin:
    fields = line.strip().split(None, 1)
    if found is None and len(fields) == 2 and fields[1] == target:
        found = fields[0]
if found is not None:
    print(found)
' "$EXECUTABLE")"
if [[ -n "$RUNNING_LAUNCHER_PID" ]]; then
  print -u2 -- "拒绝在项目启动器仍运行时原地重建（PID $RUNNING_LAUNCHER_PID）。请先关闭项目内第五人格启动器，再重试。"
  exit 70
fi

# Refresh the embedded runner and every resource it owns before copying it.
# These project-local staging commands never touch /Applications without their
# explicit --install-active mode, which is deliberately not used here.
"$PROJECT_ROOT/buildGameRunner.command"
"$PROJECT_ROOT/wineNetworkInterposer/buildAndVerify.command"
for runner_source in \
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app" \
  "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"; do
  /bin/cp "$PROJECT_ROOT/wineNetworkInterposer/build/IdentityVLoginDNSCompat.dylib" \
    "$runner_source/Contents/Resources/IdentityVLoginDNSCompat.dylib"
  /usr/bin/codesign --force --deep --sign - "$runner_source"
done
for runner_test in \
  "$PROJECT_ROOT/gameRunnerApp/tests/gameRootBinding.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/privateDesktopIsolation.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/coreAudioCapturePolicy.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/fontFallbackContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/gameModeMetadataContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/microphonePrivacyContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/nativeD3DCompilerContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/runnerLifecycleContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/stallWatchContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/mouseAccelerationSessionContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/metalHudConfigurationContract.test.command" \
  "$PROJECT_ROOT/gameRunnerApp/tests/winePrefixCleanup.test.command"; do
  print -- "验证 runner：${runner_test:t}"
  /bin/zsh "$runner_test"
done
/bin/bash "$PROJECT_ROOT/runtimeAssembly/tests/runSelfbuiltGameR4MetalHud.test.command"
"$PROJECT_ROOT/buildIdentityVCommandGraveForwarder.command"
"$PROJECT_ROOT/wineAudioInterposer/buildAndVerify.command"
"$PROJECT_ROOT/stageIdentityVAudioInterposer.command"
"$PROJECT_ROOT/buildIdentityVMouseAccelerationController.command"
"$PROJECT_ROOT/buildIdentityVFunctionKeyController.command"
for runner_source in "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app" "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"; do
  /usr/bin/install -m 755 "$PROJECT_ROOT/functionKeyController/build/IdentityVFunctionKeyController" "$runner_source/Contents/Resources/IdentityVFunctionKeyController"
  /usr/bin/codesign --force --deep --sign - "$runner_source"
done
"$PROJECT_ROOT/privilegedHelpers/buildIdentityVPrivilegedStateTool.command"
/bin/zsh "$PROJECT_ROOT/privilegedHelpers/idvLoginReadiness.test.command"
/bin/zsh "$PROJECT_ROOT/privilegedHelpers/idvLoginJob.test.command"

if [[ ! -x "$RESTART_SOURCE" ]]; then
  print -u2 -- "缺少可执行的快速重启组件：$RESTART_SOURCE"
  exit 1
fi
if [[ ! -x "$STOP_LOGIN_SOURCE" || ! -f "$ROUTE_SOURCE" ]]; then
  print -u2 -- "缺少启动器内嵌的停止组件或路线说明。"
  exit 1
fi
if [[ ! -f "$PRODUCT_MANAGER_SOURCE" || ! -x "$PRODUCT_MANAGER_WRAPPER" || ! -f "$PRODUCT_CATALOG" ]]; then
  print -u2 -- "缺少双服启动器组件源码或产品目录。"
  exit 1
fi
if [[ -z "$GO_BIN" || ! -x "$GO_BIN" || ! -f "$DOWNLOAD_SUPERVISOR_ROOT/go.mod" || ! -f "$MANIFEST_PLANNER_ROOT/go.mod" || ! -f "$CORE_BOOTSTRAP_ROOT/go.mod" || ! -f "$GLOBAL_ADAPTER_ROOT/go.mod" || ! -f "$RUNTIME_BOOTSTRAP_ROOT/go.mod" ]]; then
  print -u2 -- "缺少 Go 构建器或 clean-room 游戏下载 helper 源码。"
  exit 1
fi
if [[ ! -f "$RUNTIME_BOOTSTRAP_MANIFEST_SOURCE" || ! -f "$RUNTIME_CATALOG_SOURCE" || ! -d "$RUNTIME_PATCH_ROOT" || ! -x "$RUNTIME_PATCH_AUDIT" ]]; then
  print -u2 -- "缺少 runtime bootstrap 的 manifest、catalog 或已核验 patch payload。"
  print -u2 -- "请先运行 runtimeBootstrap/stageRuntimePatchPayloads.command。"
  exit 1
fi
for patch in winemac.so libgmp.10.dylib libpcre2-8.0.dylib libzstd.1.dylib; do
  [[ -f "$RUNTIME_PATCH_ROOT/$patch" && ! -L "$RUNTIME_PATCH_ROOT/$patch" ]] || { print -u2 -- "缺少 runtime patch：$patch"; exit 1; }
done
if [[ ! -f "$CORE_COMPONENT_MANIFEST_SOURCE" || ! -f "$IDV_LOGIN_COMPONENT_MANIFEST_SOURCE" || ! -f "$DIAGNOSTIC_EXPORTER_SOURCE" ]]; then
  print -u2 -- "缺少组件清单或原生诊断包导出器。"
  exit 1
fi
[[ -x "$IDV_LOGIN_INSTALLER_SOURCE" && -f "$IDV_LOGIN_DOWNLOADER_ROOT/go.mod" && -f "$IDV_LOGIN_DOWNLOADER_ROOT/main.go" ]] || { print -u2 -- "缺少 IDV Login 按需组件安装器或下载器。"; exit 1; }
if [[ ! -f "$DOWNLOAD_SUPERVISOR_ROOT/THIRD_PARTY_NOTICES.md" || ! -f "$MANIFEST_PLANNER_ROOT/THIRD_PARTY_NOTICES" ]]; then
  print -u2 -- "缺少游戏下载 helper 的第三方许可证声明。"
  exit 1
fi

/bin/rm -rf "$APP_PATH" "$BUILD_ROOT/第五人格 Mac.app" "$BUILD_ROOT/第五人格工具箱.app"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$THIRD_PARTY_DIR" "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework AVFoundation \
  "$HEALTH_SOURCE" \
  "$RESOURCE_SOURCE" \
  "$DENSE_SOURCE" \
  "$SOURCE_ROOT"/Sources/*.swift \
  -o "$EXECUTABLE"

/usr/bin/xcrun swiftc \
  -swift-version 5 -warnings-as-errors -O -parse-as-library \
  -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -framework AppKit -framework SwiftUI \
  "$PROMPT_PROTOCOL" "$SOURCE_ROOT/PromptHelper/IdentityVHangPrompt.swift" \
  -o "$PROMPT_HELPER"
"$PROMPT_HELPER" --self-test
/usr/bin/codesign --force --sign - --identifier com.xunfeng.identityv.launcher.hang-prompt "$PROMPT_HELPER"

# 麦克风授权辅助进程（原因/边界见 playerLauncherApp/MicHelper/main.swift）：
# 真正发起系统申请的是这个子进程，TCC 的责任方因此是启动器（带 NSMicrophoneUsageDescription），
# 万一被拒也只终止子进程，不会像在 App 内直接 requestAccess 那样被杀掉本体。
/usr/bin/xcrun swiftc \
  -swift-version 5 -warnings-as-errors -O \
  -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -framework AVFoundation \
  "$SOURCE_ROOT/MicHelper/main.swift" \
  -o "$HELPERS_DIR/IdentityVMicrophoneAuthorization"
# 冒烟自检：只读查询不触发 TCC，任何责任方下都安全；只校验输出契约。
"$HELPERS_DIR/IdentityVMicrophoneAuthorization" --status | /usr/bin/grep -q '^MICROPHONE_AUTHORIZATION='
/usr/bin/codesign --force --sign - \
  --identifier com.xunfeng.identityv.launcher.microphone-authorization \
  "$HELPERS_DIR/IdentityVMicrophoneAuthorization"
# 输出解析自检（不发起 TCC 调用，任何责任方下都安全）：这道解析决定"继续启动游戏"还是
# "拦下来引导去设置"，解析错会让她看到与实际不符的提示，所以固定用例钉住行为。
/usr/bin/xcrun swiftc \
  -swift-version 5 -warnings-as-errors -O \
  -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -framework AVFoundation -framework AppKit \
  "$SOURCE_ROOT/Sources/MicrophoneAuthorization.swift" \
  "$SOURCE_ROOT/Tests/MicrophoneAuthorizationSelfTest/main.swift" \
  -o "$BUILD_ROOT/microphone-authorization-self-test"
"$BUILD_ROOT/microphone-authorization-self-test"

/bin/cp "$SOURCE_ROOT/Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$SOURCE_ROOT/IdentityVLauncher.icns" "$RESOURCES_DIR/IdentityVLauncher.icns"
/bin/cp "$RESTART_SOURCE" "$RESTART_DESTINATION"
/bin/cp "$STOP_LOGIN_SOURCE" "$STOP_LOGIN_DESTINATION"
/bin/cp "$ROUTE_SOURCE" "$ROUTE_DESTINATION"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  "$PRODUCT_MANAGER_SOURCE" \
  -o "$PRODUCT_MANAGER_DESTINATION"
/bin/cp "$PRODUCT_MANAGER_WRAPPER" "$PRODUCT_MANAGER_WRAPPER_DESTINATION"
/bin/cp "$PRODUCT_CATALOG" "$PRODUCT_CATALOG_DESTINATION"
/bin/cp "$RUNTIME_BOOTSTRAP_MANIFEST_SOURCE" "$RUNTIME_BOOTSTRAP_MANIFEST_DESTINATION"
/bin/cp "$RUNTIME_CATALOG_SOURCE" "$RUNTIME_CATALOG_DESTINATION"
/bin/cp -R "$RUNTIME_PATCH_ROOT" "$RUNTIME_PATCH_DESTINATION"
"$RUNTIME_PATCH_AUDIT" "$APP_PATH"
/bin/cp "$CORE_COMPONENT_MANIFEST_SOURCE" "$CORE_COMPONENT_MANIFEST_DESTINATION"
/bin/cp "$IDV_LOGIN_COMPONENT_MANIFEST_SOURCE" "$IDV_LOGIN_COMPONENT_MANIFEST_DESTINATION"
/bin/cp "$IDV_LOGIN_INSTALLER_SOURCE" "$IDV_LOGIN_PAYLOAD_DESTINATION/installIdentityVPasswordlessHelpers.command"
/bin/cp "$IDV_LOGIN_COMPONENT_MANIFEST_SOURCE" "$IDV_LOGIN_PAYLOAD_DESTINATION/idvLoginComponent.json"
/bin/cp "$PROJECT_ROOT/privilegedHelpers/start-idv-login.sh" "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers/start-idv-login.sh"
/bin/cp "$PROJECT_ROOT/privilegedHelpers/stop-idv-login.sh" "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers/stop-idv-login.sh"
/bin/cp "$PROJECT_ROOT/privilegedHelpers/idv-login-job.sh" "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers/idv-login-job.sh"
/bin/cp "$PROJECT_ROOT/privilegedHelpers/launch-game-as-console-user" "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers/launch-game-as-console-user"
/bin/cp "$PROJECT_ROOT/.build/identityv-state-tool" "$IDV_LOGIN_PAYLOAD_DESTINATION/identityv-state-tool"
/bin/cp "$PROJECT_ROOT/migrateIdvLoginHotfixState.py" "$IDV_LOGIN_PAYLOAD_DESTINATION/migrateIdvLoginHotfixState.py"
/bin/cp "$PROJECT_ROOT/uninstaller/uninstallIdentityVPreview.command" "$IDV_LOGIN_PAYLOAD_DESTINATION/uninstallIdentityVPreview.command"
/bin/chmod 755 "$IDV_LOGIN_PAYLOAD_DESTINATION/installIdentityVPasswordlessHelpers.command" \
  "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers/start-idv-login.sh" \
  "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers/stop-idv-login.sh" \
  "$IDV_LOGIN_PAYLOAD_DESTINATION/privilegedHelpers/launch-game-as-console-user" \
  "$IDV_LOGIN_PAYLOAD_DESTINATION/identityv-state-tool" \
  "$IDV_LOGIN_PAYLOAD_DESTINATION/uninstallIdentityVPreview.command"
/bin/chmod 644 "$IDV_LOGIN_PAYLOAD_DESTINATION/idvLoginComponent.json" "$IDV_LOGIN_PAYLOAD_DESTINATION/migrateIdvLoginHotfixState.py"
/usr/bin/ditto "$RUNNER_SOURCE_APP" "$RUNNER_DESTINATION_APP"
# Always compile the bounded foreground helper from this source revision.
/usr/bin/xcrun swiftc -O -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  -framework AppKit -framework CoreGraphics "$PROJECT_ROOT/gameActivator/main.swift" \
  -o "$RUNNER_DESTINATION_APP/Contents/Resources/IdentityVGameActivator"
"$RUNNER_DESTINATION_APP/Contents/Resources/IdentityVGameActivator" --self-test
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  "$DIAGNOSTIC_EXPORTER_SOURCE" \
  -o "$DIAGNOSTIC_EXPORTER_DESTINATION"
(
  cd "$DOWNLOAD_SUPERVISOR_ROOT"
  "$GO_BIN" test ./...
  /usr/bin/env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    "$GO_BIN" build -trimpath -buildvcs=false -ldflags '-s -w' \
    -o "$DOWNLOAD_SUPERVISOR_DESTINATION" .
)
(
  cd "$MANIFEST_PLANNER_ROOT"
  "$GO_BIN" test ./...
  /usr/bin/env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    "$GO_BIN" build -trimpath -buildvcs=false -ldflags '-s -w' \
    -o "$MANIFEST_PLANNER_DESTINATION" .
)
(
  cd "$CORE_BOOTSTRAP_ROOT"
  "$GO_BIN" test ./...
  /usr/bin/env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    "$GO_BIN" build -trimpath -buildvcs=false -ldflags '-s -w' \
    -o "$CORE_BOOTSTRAP_DESTINATION" .
)
(
  cd "$GLOBAL_ADAPTER_ROOT"
  "$GO_BIN" test ./...
  "$GO_BIN" vet ./...
  /usr/bin/env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    "$GO_BIN" build -trimpath -buildvcs=false -ldflags '-s -w' \
    -o "$GLOBAL_ADAPTER_DESTINATION" .
)
(
  cd "$RUNTIME_BOOTSTRAP_ROOT"
  "$GO_BIN" test ./...
  "$GO_BIN" vet ./...
  /usr/bin/env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    "$GO_BIN" build -trimpath -buildvcs=false -ldflags '-s -w' \
    -o "$RUNTIME_BOOTSTRAP_DESTINATION" .
)
(
  cd "$IDV_LOGIN_DOWNLOADER_ROOT"
  "$GO_BIN" test ./...
  /usr/bin/env CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 "$GO_BIN" build -trimpath -buildvcs=false -ldflags '-s -w' -o "$IDV_LOGIN_DOWNLOADER_DESTINATION" .
)
/bin/cp "$DOWNLOAD_SUPERVISOR_ROOT/THIRD_PARTY_NOTICES.md" \
  "$THIRD_PARTY_DIR/IdentityVDownloadSupervisor.txt"
/bin/cp "$MANIFEST_PLANNER_ROOT/THIRD_PARTY_NOTICES" \
  "$THIRD_PARTY_DIR/IdentityVManifestPlanner.txt"
/bin/chmod 755 \
  "$EXECUTABLE" \
  "$RESTART_DESTINATION" \
  "$STOP_LOGIN_DESTINATION" \
  "$PRODUCT_MANAGER_DESTINATION" \
  "$PRODUCT_MANAGER_WRAPPER_DESTINATION" \
  "$DOWNLOAD_SUPERVISOR_DESTINATION" \
  "$MANIFEST_PLANNER_DESTINATION" \
  "$CORE_BOOTSTRAP_DESTINATION" \
  "$GLOBAL_ADAPTER_DESTINATION" \
  "$RUNTIME_BOOTSTRAP_DESTINATION" \
  "$IDV_LOGIN_DOWNLOADER_DESTINATION" \
  "$DIAGNOSTIC_EXPORTER_DESTINATION"

/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.xunfeng.identityv.toolbox.product-manager \
  "$PRODUCT_MANAGER_DESTINATION"
/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.xunfeng.identityv.toolbox.download-supervisor \
  "$DOWNLOAD_SUPERVISOR_DESTINATION"
/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.xunfeng.identityv.toolbox.manifest-planner \
  "$MANIFEST_PLANNER_DESTINATION"
/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.xunfeng.identityv.toolbox.downloader-core-bootstrap \
  "$CORE_BOOTSTRAP_DESTINATION"
/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.xunfeng.identityv.toolbox.global-adapter \
  "$GLOBAL_ADAPTER_DESTINATION"
/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.xunfeng.identityv.toolbox.runtime-bootstrap \
  "$RUNTIME_BOOTSTRAP_DESTINATION"
/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.xunfeng.identityv.toolbox.diagnostic-exporter \
  "$DIAGNOSTIC_EXPORTER_DESTINATION"
# 由内到外签整个启动器 bundle（含内嵌 IdentityVGameRunner.app 与全部辅助二进制，
# identifier 沿用上面指定的值）。不再用 --deep：它只把外层选项套一遍，内层仍会是
# ad-hoc，产不出可公证的 Developer ID 树。
identityv_sign_bundle_tree "$APP_PATH"
"$RUNTIME_PATCH_AUDIT" "$APP_PATH"

/usr/bin/plutil -lint "$CONTENTS/Info.plist"
identityv_verify_bundle_tree "$APP_PATH"
identityv_verify_bundle_tree "$RUNNER_DESTINATION_APP"
/bin/zsh "$PROJECT_ROOT/gameRunnerApp/tests/microphonePrivacyContract.test.command" "$APP_PATH"
/usr/bin/file "$EXECUTABLE"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -D TOOLBOX_ENV_SELF_TEST \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  "$SOURCE_ROOT/Sources/ToolboxModels.swift" \
  -o "$ENV_SELF_CHECK"
"$ENV_SELF_CHECK"
/bin/rm -f "$ENV_SELF_CHECK"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -D TOOLBOX_INSTALL_ATTEMPT_LOG_SELF_TEST \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  "$SOURCE_ROOT/Sources/ToolboxModels.swift" \
  "$SOURCE_ROOT/Sources/InstallAttemptLog.swift" \
  -o "$INSTALL_ATTEMPT_LOG_SELF_CHECK"
"$INSTALL_ATTEMPT_LOG_SELF_CHECK"
/bin/rm -f "$INSTALL_ATTEMPT_LOG_SELF_CHECK"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -D TOOLBOX_LAUNCH_LOCATION_SELF_TEST \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework SwiftUI \
  "$SOURCE_ROOT/Sources/IdentityVToolboxApp.swift" \
  -o "$LAUNCH_LOCATION_SELF_CHECK"
"$LAUNCH_LOCATION_SELF_CHECK"
/bin/rm -f "$LAUNCH_LOCATION_SELF_CHECK"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -D TOOLBOX_PROCESS_SELF_TEST \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework AVFoundation \
  "$SOURCE_ROOT/Sources/ToolboxModels.swift" \
  "$SOURCE_ROOT/Sources/MicrophoneAuthorization.swift" \
  "$SOURCE_ROOT/Sources/InstallAttemptLog.swift" \
  "$DENSE_SOURCE" \
  "$HEALTH_SOURCE" \
  "$RESOURCE_SOURCE" \
  "$SOURCE_ROOT/Sources/LauncherHangMonitor.swift" \
  "$PROMPT_PROTOCOL" "$PROMPT_CLIENT" \
  "$SOURCE_ROOT/Sources/ToolboxViewModel.swift" \
  -o "$PROCESS_SELF_CHECK"
"$PROCESS_SELF_CHECK"
/bin/rm -f "$PROCESS_SELF_CHECK"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -D TOOLBOX_LAUNCHER_HANG_SELF_TEST \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework IOKit \
  "$SOURCE_ROOT/Sources/ToolboxModels.swift" \
  "$HEALTH_SOURCE" \
  "$RESOURCE_SOURCE" \
  "$SOURCE_ROOT/Sources/LauncherHangMonitor.swift" \
  "$PROMPT_PROTOCOL" "$PROMPT_CLIENT" \
  -o "$LAUNCHER_HANG_SELF_CHECK"
"$LAUNCHER_HANG_SELF_CHECK"
/bin/rm -f "$LAUNCHER_HANG_SELF_CHECK"

"$PRODUCT_MANAGER_DESTINATION" self-test
"$DOWNLOAD_SUPERVISOR_DESTINATION" self-test
"$MANIFEST_PLANNER_DESTINATION" self-test
"$CORE_BOOTSTRAP_DESTINATION" self-test
if [[ -n "${IDENTITYV_RUNTIME_VERIFY_CANDIDATE:-}" ]]; then
  [[ "$IDENTITYV_RUNTIME_VERIFY_CANDIDATE" == /* ]] || { print -u2 -- "IDENTITYV_RUNTIME_VERIFY_CANDIDATE 必须是绝对路径。"; exit 64; }
  "$RUNTIME_BOOTSTRAP_DESTINATION" verify-tree --manifest "$RUNTIME_BOOTSTRAP_MANIFEST_DESTINATION" --tree "$IDENTITYV_RUNTIME_VERIFY_CANDIDATE" >/dev/null
fi
"$DIAGNOSTIC_EXPORTER_DESTINATION" --self-test
"$IDV_LOGIN_PAYLOAD_DESTINATION/installIdentityVPasswordlessHelpers.command" --payload-root "$IDV_LOGIN_PAYLOAD_DESTINATION" --verify-only
"$IDV_LOGIN_DOWNLOADER_DESTINATION" --self-test
! /usr/bin/find "$APP_PATH" -iname 'idv-login.raw' -o -iname 'idv-login-v*-mac' | /usr/bin/grep -q .
/usr/bin/file "$DOWNLOAD_SUPERVISOR_DESTINATION" | /usr/bin/grep -q 'arm64'
/usr/bin/file "$MANIFEST_PLANNER_DESTINATION" | /usr/bin/grep -q 'arm64'
/usr/bin/file "$CORE_BOOTSTRAP_DESTINATION" | /usr/bin/grep -q 'arm64'
/usr/bin/file "$DIAGNOSTIC_EXPORTER_DESTINATION" | /usr/bin/grep -q 'arm64'
/usr/bin/file "$RUNTIME_BOOTSTRAP_DESTINATION" | /usr/bin/grep -q 'arm64'

"$PROJECT_ROOT/runtimeManifest/auditMachODeploymentTargets.command" "$APP_PATH"

PRODUCT_TEST_HOME="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$PRODUCT_TEST_HOME"' EXIT
HOME="$PRODUCT_TEST_HOME" "$PRODUCT_MANAGER_DESTINATION" status --json | /usr/bin/plutil -extract schemaVersion raw - | /usr/bin/grep -qx '1'
# `select` correctly refuses while any real game is running. Keep the build's
# offline self-test independent of the host session; mutation/0600 checks live
# in IdentityVProductManager's own deterministic self-test.

print -- "构建完成：$APP_PATH"
