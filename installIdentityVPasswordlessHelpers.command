#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
# In a release this is the app's Contents/Resources/InstallerPayload directory.
# Keep every privileged input relative to it; never fall back to a developer
# checkout or an already-installed component.
PAYLOAD_ROOT="$SCRIPT_ROOT"
PROJECT_ROOT="$PAYLOAD_ROOT" # Compatibility name retained by static checks.
DEFAULT_MANIFEST="$PAYLOAD_ROOT/idvLoginComponent.json"
COMPONENT_SOURCE=""
MANIFEST_SOURCE="$DEFAULT_MANIFEST"
VERIFY_ONLY=false

while (( $# > 0 )); do
  case "$1" in
    --root)
      shift
      ;;
    --payload-root)
      [[ $# -ge 2 && "$2" == /* && -d "$2" && ! -L "$2" ]] || { /usr/bin/printf '%s\n' '--payload-root 必须是绝对普通目录' >&2; exit 2; }
      PAYLOAD_ROOT="${2:A}"
      PROJECT_ROOT="$PAYLOAD_ROOT"
      DEFAULT_MANIFEST="$PAYLOAD_ROOT/idvLoginComponent.json"
      MANIFEST_SOURCE="$DEFAULT_MANIFEST"
      shift 2
      ;;
    --component)
      [[ $# -ge 2 ]] || { /usr/bin/printf '%s\n' '--component 缺少路径' >&2; exit 2; }
      COMPONENT_SOURCE="$2"
      shift 2
      ;;
    --manifest)
      [[ $# -ge 2 ]] || { /usr/bin/printf '%s\n' '--manifest 缺少路径' >&2; exit 2; }
      MANIFEST_SOURCE="$2"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY=true
      shift
      ;;
    *)
      /usr/bin/printf '未知参数：%s\n' "$1" >&2
      exit 2
      ;;
  esac
done

[[ -f "$MANIFEST_SOURCE" ]] || {
  /usr/bin/printf '缺少组件清单：%s\n' "$MANIFEST_SOURCE" >&2
  exit 1
}

extract_manifest_string() {
  local key="$1" value
  value="$(/usr/bin/plutil -extract "$key" raw -expect string -o - "$MANIFEST_SOURCE" 2>/dev/null)" || {
    /usr/bin/printf '组件清单字段无效：%s\n' "$key" >&2
    return 1
  }
  [[ -n "$value" ]] || {
    /usr/bin/printf '组件清单字段为空：%s\n' "$key" >&2
    return 1
  }
  /usr/bin/printf '%s' "$value"
}
VERSION="$(extract_manifest_string version)"
ASSET_NAME="$(extract_manifest_string assetName)"
EXPECTED_SHA256="$(extract_manifest_string sha256)"
RELEASE_URL="$(extract_manifest_string releaseURL)"
EXPECTED_SIZE="$(/usr/bin/plutil -extract byteSize raw -expect integer -o - "$MANIFEST_SOURCE" 2>/dev/null)" || {
  /usr/bin/printf '组件清单字段无效：byteSize\n' >&2
  exit 1
}

[[ "$VERSION" == [0-9]* && "$VERSION" != *[^0-9A-Za-z.-]* ]] || {
  /usr/bin/printf '组件版本格式异常：%s\n' "$VERSION" >&2
  exit 1
}
[[ "$EXPECTED_SHA256" != *[^0-9a-f]* && ${#EXPECTED_SHA256} -eq 64 ]] || {
  /usr/bin/printf '组件 SHA-256 格式异常。\n' >&2
  exit 1
}
[[ "$EXPECTED_SIZE" == <-> && "$EXPECTED_SIZE" -gt 0 ]] || {
  /usr/bin/printf '组件大小格式异常。\n' >&2
  exit 1
}

HELPER_SOURCE_DIR="$PAYLOAD_ROOT/privilegedHelpers"
STATE_TOOL_SOURCE="$PAYLOAD_ROOT/identityv-state-tool"
MIGRATION_SOURCE="$PAYLOAD_ROOT/migrateIdvLoginHotfixState.py"
UNINSTALLER_SOURCE="$PAYLOAD_ROOT/uninstallIdentityVPreview.command"

verify_payload() {
  for helper_source in \
    "$HELPER_SOURCE_DIR/start-idv-login.sh" \
    "$HELPER_SOURCE_DIR/stop-idv-login.sh" \
    "$HELPER_SOURCE_DIR/idv-login-job.sh" \
    "$HELPER_SOURCE_DIR/launch-game-as-console-user"; do
    [[ -f "$helper_source" && ! -L "$helper_source" ]] || {
      /usr/bin/printf '缺少 installer payload：%s\n' "$helper_source" >&2; return 1;
    }
    /bin/zsh -n "$helper_source"
  done
  [[ -x "$STATE_TOOL_SOURCE" && ! -L "$STATE_TOOL_SOURCE" ]] || {
    /usr/bin/printf '缺少原生 helper 状态工具。\n' >&2; return 1;
  }
  "$STATE_TOOL_SOURCE" --self-test
  [[ -f "$MIGRATION_SOURCE" && ! -L "$MIGRATION_SOURCE" ]] || {
    /usr/bin/printf '缺少跨版本热修复迁移器。\n' >&2; return 1;
  }
  [[ -f "$UNINSTALLER_SOURCE" && ! -L "$UNINSTALLER_SOURCE" ]] || {
    /usr/bin/printf '缺少预览卸载器。\n' >&2; return 1;
  }
  /bin/zsh -n "$UNINSTALLER_SOURCE"
}

if [[ "$VERIFY_ONLY" == true && -z "$COMPONENT_SOURCE" ]]; then
  # Bundle structural verification deliberately does not require (or permit)
  # a re-distributed idv-login binary.
  COMPONENT_SOURCE=""
elif [[ -z "$COMPONENT_SOURCE" ]]; then
  /usr/bin/printf '安装必须显式传入 --component。\n' >&2
  exit 2
fi

if [[ "$VERIFY_ONLY" == true && -z "$COMPONENT_SOURCE" ]]; then
  verify_payload
  /usr/bin/printf 'IDV Login %s 安装输入复验通过。\n' "$VERSION"
  exit 0
fi

[[ -f "$COMPONENT_SOURCE" && ! -L "$COMPONENT_SOURCE" ]] || { /usr/bin/printf '缺少已下载并校验的 IDV Login 组件。\n' >&2; exit 1; }
actual_size="$(/usr/bin/stat -f '%z' "$COMPONENT_SOURCE")"
[[ "$actual_size" == "$EXPECTED_SIZE" ]] || { /usr/bin/printf '组件大小不匹配；拒绝安装。\n' >&2; exit 1; }
actual_sha256="$(/usr/bin/shasum -a 256 "$COMPONENT_SOURCE" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$EXPECTED_SHA256" ]] || { /usr/bin/printf '组件摘要不匹配；拒绝安装。\n' >&2; exit 1; }
/usr/bin/file "$COMPONENT_SOURCE" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64' || { /usr/bin/printf '组件不是预期的原生 arm64 Mach-O；拒绝安装。\n' >&2; exit 1; }

if [[ "$VERIFY_ONLY" == true ]]; then
  verify_payload
  /usr/bin/printf 'IDV Login %s 安装输入与组件复验通过。\n' "$VERSION"
  exit 0
fi

if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
  /usr/bin/osascript - "$0" "$PAYLOAD_ROOT" "$COMPONENT_SOURCE" "$MANIFEST_SOURCE" <<'OSA'
on run argv
  set installerPath to item 1 of argv
  set payloadRoot to item 2 of argv
  set componentPath to item 3 of argv
  set manifestPath to item 4 of argv
  set commandText to quoted form of installerPath & " --root --payload-root " & quoted form of payloadRoot & " --component " & quoted form of componentPath & " --manifest " & quoted form of manifestPath
  do shell script commandText with administrator privileges
end run
OSA
  exit 0
fi

HELPER_DIR="/Library/PrivilegedHelperTools/identityv-on-mac"
START_HELPER="$HELPER_DIR/start-idv-login.sh"
STOP_HELPER="$HELPER_DIR/stop-idv-login.sh"
GAME_BRIDGE="$HELPER_DIR/launch-game-as-console-user"
STATE_TOOL="$HELPER_DIR/identityv-state-tool"
LEGACY_PRIORITY_HELPER="$HELPER_DIR/fix-game-priority.sh"
SUDOERS_FILE="/etc/sudoers.d/identityv-on-mac"
COMPONENT_ROOT="/Library/Application Support/IdentityVOnMac/Components/idv-login"
INSTALL_MANIFEST="/Library/Application Support/IdentityVOnMac/install-manifest.json"
TARGET_DIR="$COMPONENT_ROOT/$VERSION"
CURRENT_LINK="$COMPONENT_ROOT/current"
LEGACY_BIN="$HELPER_DIR/idv-login-v6.1.0-mac-mac"
MIGRATION_OUTPUT=""

# This installer runs its privileged phase as root, so $USER/$HOME describe root.
# Resolve the active Aqua console session instead and reject loginwindow, root, and
# directory-service inconsistencies before placing an account name in sudoers.
resolve_console_user() {
  local account_uid home_owner
  CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
  CONSOLE_UID="$(/usr/bin/stat -f '%u' /dev/console)"
  [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]] || {
    /usr/bin/printf '未检测到可安装组件的 macOS 桌面用户；请登录图形界面后重试。\n' >&2
    return 1
  }
  [[ "$CONSOLE_USER" != *[!A-Za-z0-9._-]* && "$CONSOLE_USER" != .* && "$CONSOLE_USER" != *..* ]] || {
    /usr/bin/printf '当前桌面用户名格式不安全；拒绝写入 sudoers。\n' >&2
    return 1
  }
  [[ "$CONSOLE_UID" == <-> && "$CONSOLE_UID" -ge 500 ]] || {
    /usr/bin/printf '当前桌面用户 UID 无效。\n' >&2
    return 1
  }
  account_uid="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" UniqueID 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')"
  CONSOLE_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')"
  [[ "$account_uid" == "$CONSOLE_UID" && "$CONSOLE_HOME" == /* && -d "$CONSOLE_HOME" ]] || {
    /usr/bin/printf '当前桌面用户账户信息异常。\n' >&2
    return 1
  }
  home_owner="$(/usr/bin/stat -f '%u' "$CONSOLE_HOME")"
  [[ "$home_owner" == "$CONSOLE_UID" ]] || {
    /usr/bin/printf '当前桌面用户主目录所有者异常。\n' >&2
    return 1
  }
}

verify_payload
resolve_console_user

# Reinstalling replaces the proxy's launch/stop lifecycle. Do not tear that
# shared service down under a running match; this guard also covers direct
# installer invocation outside the launcher's UI.
if /bin/ps -axo comm= | /usr/bin/awk '
  { gsub(/\\/, "/"); if ($0 ~ /(^|\/)dwrg[.]exe$/) found=1 }
  END { exit !found }
'; then
  print -u2 -- '第五人格仍在运行；请先退出游戏，再更新 IDV Login 组件。'
  exit 75
fi

current_version=""
if [[ -L "$CURRENT_LINK" ]]; then
  current_version="${$(/usr/bin/readlink "$CURRENT_LINK"):t}"
elif [[ -x "$LEGACY_BIN" ]]; then
  current_version="6.1.0-legacy"
fi

if [[ -x "$STOP_HELPER" ]]; then
  "$STOP_HELPER"
fi

legacy_pids="$(/bin/ps -axo pid=,comm= | /usr/bin/awk '
  {
    pid=$1
    $1=""
    comm=$0
    if (comm ~ /\/IdentityVOnMac\/Components\/idv-login\/.*\/idv-login$/ ||
        comm ~ /\/idv-login-v[0-9][^\/ ]*-mac(-mac)?$/) {
      print pid
    }
  }
')"
if [[ -n "$legacy_pids" ]]; then
  /usr/bin/printf '%s\n' "$legacy_pids" | while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  /bin/sleep 2
fi

if [[ -n "$current_version" && "$current_version" != "$VERSION" ]]; then
  [[ -x /usr/bin/python3 ]] || {
    /usr/bin/printf '检测到旧版 IDV Login，但此系统没有迁移旧热修复所需的兼容工具；未改动现有组件。\n' >&2
    exit 1
  }
  MIGRATION_OUTPUT="$(/usr/bin/python3 "$MIGRATION_SOURCE" \
    --work-dir "$CONSOLE_HOME/Library/Application Support/idv-login" \
    --from-version "$current_version" \
    --to-version "$VERSION" \
    --backup-owner "$CONSOLE_USER" \
    --backup-group staff)"
fi

/bin/mkdir -p "$HELPER_DIR" "$COMPONENT_ROOT"
/usr/sbin/chown root:wheel "$HELPER_DIR" "$COMPONENT_ROOT"
/bin/chmod 755 "$HELPER_DIR" "$COMPONENT_ROOT"

if [[ -x "$LEGACY_BIN" && ! -e "$COMPONENT_ROOT/6.1.0/idv-login" ]]; then
  /bin/mkdir -p "$COMPONENT_ROOT/6.1.0"
  /bin/cp -p "$LEGACY_BIN" "$COMPONENT_ROOT/6.1.0/idv-login"
  legacy_sha="$(/usr/bin/shasum -a 256 "$COMPONENT_ROOT/6.1.0/idv-login" | /usr/bin/awk '{print $1}')"
  /usr/bin/printf '{\n  "schemaVersion": 1,\n  "component": "idv-login",\n  "version": "6.1.0",\n  "source": "migrated-local-install",\n  "sha256": "%s"\n}\n' "$legacy_sha" > "$COMPONENT_ROOT/6.1.0/component.json"
  /usr/sbin/chown -R root:wheel "$COMPONENT_ROOT/6.1.0"
  /bin/chmod 755 "$COMPONENT_ROOT/6.1.0" "$COMPONENT_ROOT/6.1.0/idv-login"
  /bin/chmod 644 "$COMPONENT_ROOT/6.1.0/component.json"
fi

target_is_valid=false
if [[ -x "$TARGET_DIR/idv-login" ]]; then
  installed_sha256="$(/usr/bin/shasum -a 256 "$TARGET_DIR/idv-login" | /usr/bin/awk '{print $1}')"
  [[ "$installed_sha256" == "$EXPECTED_SHA256" ]] && target_is_valid=true
fi

if [[ "$target_is_valid" != true ]]; then
  if [[ -e "$TARGET_DIR" ]]; then
    replaced_path="$COMPONENT_ROOT/$VERSION.replaced-$(/bin/date '+%Y%m%d-%H%M%S')"
    /bin/mv "$TARGET_DIR" "$replaced_path"
  fi
  staging_dir="$(/usr/bin/mktemp -d "$COMPONENT_ROOT/.installing-$VERSION.XXXXXX")"
  /bin/cp -p "$COMPONENT_SOURCE" "$staging_dir/idv-login"
  /bin/cp -p "$MANIFEST_SOURCE" "$staging_dir/component.json"
  /usr/sbin/chown -R root:wheel "$staging_dir"
  /bin/chmod 755 "$staging_dir" "$staging_dir/idv-login"
  /bin/chmod 644 "$staging_dir/component.json"
  staged_sha256="$(/usr/bin/shasum -a 256 "$staging_dir/idv-login" | /usr/bin/awk '{print $1}')"
  [[ "$staged_sha256" == "$EXPECTED_SHA256" ]] || {
    /usr/bin/printf 'root 阶段复验失败；安装已中止，暂存目录保留：%s\n' "$staging_dir" >&2
    exit 1
  }
  /bin/mv "$staging_dir" "$TARGET_DIR"
else
  /bin/cp -p "$MANIFEST_SOURCE" "$TARGET_DIR/component.json"
  /usr/sbin/chown root:wheel "$TARGET_DIR/component.json"
  /bin/chmod 644 "$TARGET_DIR/component.json"
fi

next_link="$COMPONENT_ROOT/.current.$$"
/bin/ln -s "$VERSION" "$next_link"
/bin/mv -h -f "$next_link" "$CURRENT_LINK"
/usr/sbin/chown -h root:wheel "$CURRENT_LINK"

/bin/cp -p "$HELPER_SOURCE_DIR/start-idv-login.sh" "$START_HELPER"
/bin/cp -p "$HELPER_SOURCE_DIR/stop-idv-login.sh" "$STOP_HELPER"
/bin/cp -p "$HELPER_SOURCE_DIR/launch-game-as-console-user" "$GAME_BRIDGE"
/usr/bin/install -o root -g wheel -m 644 "$HELPER_SOURCE_DIR/idv-login-job.sh" "$HELPER_DIR/idv-login-job.sh"
/bin/cp -p "$STATE_TOOL_SOURCE" "$STATE_TOOL"
/usr/sbin/chown root:wheel "$START_HELPER" "$STOP_HELPER" "$GAME_BRIDGE" "$STATE_TOOL"
/bin/chmod 755 "$START_HELPER" "$STOP_HELPER" "$GAME_BRIDGE" "$STATE_TOOL"
if [[ -e "$LEGACY_PRIORITY_HELPER" ]]; then
  /bin/rm -f -- "$LEGACY_PRIORITY_HELPER"
fi
[[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$GAME_BRIDGE")" == "0:0:755" ]] || {
  /usr/bin/printf '游戏用户态启动桥权限设置失败。\n' >&2
  exit 1
}
[[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$STATE_TOOL")" == "0:0:755" ]] || {
  /usr/bin/printf '原生 helper 状态工具权限设置失败。\n' >&2
  exit 1
}
/usr/bin/codesign --verify --strict "$STATE_TOOL"

/bin/cat > "$SUDOERS_FILE" <<SUDOERS
# Identity V on Mac: allow the active desktop user to run only these root-owned helpers.
$CONSOLE_USER ALL=(root) NOPASSWD: $START_HELPER, $START_HELPER --status
$CONSOLE_USER ALL=(root) NOPASSWD: $STOP_HELPER
SUDOERS
/usr/sbin/chown root:wheel "$SUDOERS_FILE"
/bin/chmod 440 "$SUDOERS_FILE"
/usr/sbin/visudo -cf "$SUDOERS_FILE"

# Keep an intentionally boring, machine-readable ownership record for the
# preview uninstaller. It contains paths and component version only—never
# account state, proxy configuration, credentials or game installation paths.
INSTALL_MANIFEST_TEMP="$INSTALL_MANIFEST.tmp.$$"
/usr/bin/printf '{\n  "schemaVersion": 1,\n  "owner": "IdentityVOnMac",\n  "idvLoginVersion": "%s",\n  "systemTargets": [\n    "/Applications/第五人格启动器.app",\n    "/Library/PrivilegedHelperTools/identityv-on-mac",\n    "/Library/Application Support/IdentityVOnMac/Components/idv-login",\n    "/etc/sudoers.d/identityv-on-mac"\n  ],\n  "managedHosts": [\n    "service.mkey.163.com",\n    "sdk-os.mpsdk.easebar.com",\n    "mgbsdk.matrix.netease.com"\n  ],\n  "networkMode": "compat-hosts-only",\n  "componentInstallAddsSystemCA": false,\n  "idvLoginFirstRunAddsSystemCA": true,\n  "idvLoginSystemCAOwnershipManifest": "/Library/Application Support/IdentityVOnMac/idv-login-system-ca.json",\n  "idvLoginSystemCARevocation": "recorded-sha1-with-root-ledger-and-exact-system-der-hash-verification",\n  "changesSystemProxy": false\n}\n' "$VERSION" > "$INSTALL_MANIFEST_TEMP"
# On current macOS, `plutil -lint` only accepts property-list syntax even
# though the extract/convert subcommands support JSON.  Parse the generated
# JSON through the converter instead of rejecting the leading `{`.
/usr/bin/plutil -convert json -o /dev/null "$INSTALL_MANIFEST_TEMP"
/usr/bin/plutil -insert idvLoginLaunchdService -string 'system/com.xunfeng.identityv.idv-login' "$INSTALL_MANIFEST_TEMP"
/usr/bin/plutil -insert idvLoginRuntimePlist -string '/var/run/identityv-on-mac/idv-login.plist' "$INSTALL_MANIFEST_TEMP"
/bin/mv -f "$INSTALL_MANIFEST_TEMP" "$INSTALL_MANIFEST"
/usr/sbin/chown root:wheel "$INSTALL_MANIFEST"
/bin/chmod 644 "$INSTALL_MANIFEST"

# A power loss or an older installer which failed after writing JSON may leave
# only this exact root-owned temporary sibling.  The final manifest is already
# committed at this point, so remove stale regular siblings and nothing else.
for stale_manifest in "$INSTALL_MANIFEST".tmp.*(N); do
  [[ -f "$stale_manifest" && ! -L "$stale_manifest" ]] || continue
  [[ "$(/usr/bin/stat -f '%u' "$stale_manifest")" == "0" ]] || continue
  /bin/rm -f -- "$stale_manifest"
done

"$STOP_HELPER"

/usr/bin/printf '已安装 IDV Login 组件 %s。\n' "$VERSION"
/usr/bin/printf '组件入口：%s\n' "$CURRENT_LINK/idv-login"
/usr/bin/printf '上游版本：%s\n' "$RELEASE_URL"
if [[ -n "$MIGRATION_OUTPUT" ]]; then
  /usr/bin/printf '跨版本热修复隔离：%s\n' "$MIGRATION_OUTPUT"
fi
