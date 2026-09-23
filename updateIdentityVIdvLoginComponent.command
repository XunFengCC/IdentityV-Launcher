#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
MANIFEST="$PROJECT_ROOT/idvLoginComponent.json"
INSTALLER="$PROJECT_ROOT/installIdentityVPasswordlessHelpers.command"
LAUNCHER_SHIM_INSTALLER="$PROJECT_ROOT/installIdentityVIdvLoginLauncherShim.command"
COMPONENT_ROOT="/Library/Application Support/IdentityVOnMac/Components/idv-login"

[[ -f "$MANIFEST" ]] || { /usr/bin/printf '缺少组件清单：%s\n' "$MANIFEST" >&2; exit 1; }
[[ -x "$INSTALLER" ]] || { /usr/bin/printf '缺少组件安装器：%s\n' "$INSTALLER" >&2; exit 1; }

manifest_fields="$(/usr/bin/python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in ("version", "assetName", "downloadURL", "sha256"):
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"invalid manifest field: {key}")
print(*(data[key] for key in ("version", "assetName", "downloadURL", "sha256")), sep="\n")
PY
)"
fields=("${(@f)manifest_fields}")
(( ${#fields} == 4 )) || { /usr/bin/printf '组件清单字段数量异常。\n' >&2; exit 1; }
VERSION="$fields[1]"
ASSET_NAME="$fields[2]"
DOWNLOAD_URL="$fields[3]"
EXPECTED_SHA256="$fields[4]"

component_source=""
for installed_candidate in \
  "$COMPONENT_ROOT/$VERSION/idv-login" \
  "$COMPONENT_ROOT/current/idv-login"; do
  [[ -x "$installed_candidate" ]] || continue
  installed_sha256="$(/usr/bin/shasum -a 256 "$installed_candidate" | /usr/bin/awk '{print $1}')"
  if [[ "$installed_sha256" == "$EXPECTED_SHA256" ]]; then
    component_source="$installed_candidate"
    /usr/bin/printf 'IDV Login %s 已在组件槽中，跳过重复下载；将刷新整体集成。\n' "$VERSION"
    break
  fi
done

temporary_dir=""
cleanup() {
  if [[ -n "$temporary_dir" && "$temporary_dir" == /private/tmp/identityv-idv-login-update.* && -d "$temporary_dir" ]]; then
    /bin/rm -rf -- "$temporary_dir"
  fi
}
trap cleanup EXIT

if [[ -z "$component_source" ]]; then
  temporary_dir="$(/usr/bin/mktemp -d /private/tmp/identityv-idv-login-update.XXXXXX)"
  component_source="$temporary_dir/$ASSET_NAME"
  /usr/bin/printf '正在下载 IDV Login %s（约 197 MB）…\n' "$VERSION"
  /usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 2 \
    --output "$component_source" \
    "$DOWNLOAD_URL"
  actual_sha256="$(/usr/bin/shasum -a 256 "$component_source" | /usr/bin/awk '{print $1}')"
  [[ "$actual_sha256" == "$EXPECTED_SHA256" ]] || {
    /usr/bin/printf '下载摘要不匹配；拒绝继续。\n期望：%s\n实际：%s\n' "$EXPECTED_SHA256" "$actual_sha256" >&2
    exit 1
  }
  /bin/chmod 755 "$component_source"
  /usr/bin/printf '摘要复验通过；正在做无状态启动检查…\n'
  "$component_source" --help >/dev/null
fi

/usr/bin/printf '接下来会出现一次 macOS 管理员授权：停止旧组件、保留迁移前配置、原子切换版本并刷新限定 helper。\n'
"$INSTALLER" --component "$component_source" --manifest "$MANIFEST"
if [[ -x "$LAUNCHER_SHIM_INSTALLER" ]]; then
  "$LAUNCHER_SHIM_INSTALLER"
fi
/usr/bin/printf 'IDV Login %s 组件更新完成；未自动启动游戏。\n' "$VERSION"
