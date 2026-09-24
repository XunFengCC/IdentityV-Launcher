#!/bin/zsh
# Package the selected build as a release disk image. Signing and notarization
# follow the resolved identity. This never installs, launches, authorizes, or
# modifies a user's existing game/runtime.
set -euo pipefail

script_dir=${0:A:h}
command_name=${0:t}
project_root=${script_dir:h}
build_root="${IDENTITYV_BUILD_ROOT:-$project_root/playerLauncherApp/build}"
[[ "$build_root" == /* ]] || { print -u2 -- "IDENTITYV_BUILD_ROOT 必须是绝对路径。"; exit 64; }
source_app="$build_root/第五人格启动器.app"
notice_root="$project_root/notices/.build/ReleaseMaterials"
dmgbuild="$script_dir/.venv/bin/dmgbuild"
dmg_settings="$script_dir/dmgSettings.py"
dmg_background_source="$script_dir/dmgBackground.svg"
dmg_background_generator="$script_dir/makeDmgBackground.swift"
runtime_patch_audit="$project_root/runtimeBootstrap/verifyRuntimePatchPayloads.command"
output_root="$script_dir/build"
rebuild=0

usage() {
  print -- "Usage: $command_name [--rebuild] [--output DIRECTORY]"
  print -- "  --rebuild             rebuild the source app before packaging (no install/launch)"
  print -- "  --output DIRECTORY    place artifacts here (default: releasePackaging/build)"
}

while (( $# > 0 )); do
  case "$1" in
    --rebuild) rebuild=1 ;;
    --output)
      (( $# >= 2 )) || { print -u2 -- "--output requires a directory"; exit 2; }
      output_root="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

if (( rebuild )); then
  "$project_root/buildPlayerLauncher.command"
fi

[[ -d "$source_app" ]] || { print -u2 -- "Missing built app: $source_app"; print -u2 -- "Run with --rebuild or build it first."; exit 1; }
release_version="$(/usr/libexec/PlistBuddy -c 'Print IdentityVReleaseVersion' "$source_app/Contents/Info.plist")"
[[ "$release_version" == [0-9]* && "$release_version" != *[^a-zA-Z0-9.-]* ]] || { print -u2 -- "发行版本格式无效。"; exit 1; }
/usr/bin/python3 "$project_root/releasePackaging/releaseIdentity.py" verify \
  --repo "$project_root" --app "$source_app"
release_name="第五人格启动器-$release_version"
materials_name="$release_name-ReleaseMaterials"
/bin/zsh "$project_root/gameRunnerApp/tests/microphonePrivacyContract.test.command" "$source_app"
[[ -x "$dmgbuild" && -f "$dmg_settings" && -f "$dmg_background_source" && -f "$dmg_background_generator" && -x "$runtime_patch_audit" ]] || {
  print -u2 -- "Missing isolated DMG packaging environment or layout assets."
  print -u2 -- "Run releasePackaging/preparePackagingEnvironment.command first."
  exit 1
}
[[ -d "$notice_root/ThirdPartyNotices" && -d "$notice_root/CorrespondingSources" ]] || {
  print -u2 -- "Missing release notices/source materials: $notice_root"
  print -u2 -- "Run notices/prepareReleaseNotices.command first."; exit 1
}

# 代码签名身份（原因、优先级与边界见 signing/lib/signIdentityV.sh）。发行封包在
# Developer ID 模式下必须同时完成公证，否则产物不可分发；缺少公证凭据时直接失败，
# 而不是静默产出未公证的 DMG。
source "$project_root/signing/lib/signIdentityV.sh"
identityv_resolve_identity
notary_profile="${IDENTITYV_NOTARY_PROFILE:-}"
if [[ "$IDENTITYV_RESOLVED_KIND" == developer-id && -z "$notary_profile" ]]; then
  print -u2 -- "Developer ID 签名必须公证，但没有设置 IDENTITYV_NOTARY_PROFILE。"
  print -u2 -- "先一次性存入凭据（app 专用密码或团队 API 密钥二选一）："
  print -u2 -- "  $project_root/signing/setupNotaryCredentials.command"
  exit 64
fi

output_root=${output_root:A}
/bin/mkdir -p "$output_root"
app_dmg="$output_root/$release_name.dmg"
materials_zip="$output_root/$materials_name.zip"
checksums="$output_root/SHA256SUMS.txt"
# A release version names immutable bytes. Use a fresh output directory for a
# rebuilt candidate instead of silently replacing an earlier candidate.
for published_artifact in "$app_dmg" "$materials_zip" "$checksums"; do
  if [[ -e "$published_artifact" || -L "$published_artifact" ]]; then
    print -u2 -- "Refusing to overwrite existing release artifact: $published_artifact"
    print -u2 -- "Choose a fresh --output directory so the earlier candidate remains recoverable."
    exit 73
  fi
done
stage_root="$(/usr/bin/mktemp -d "$output_root/.stage-$release_name.XXXXXX")"
[[ "$stage_root" == "$output_root"/.stage-"$release_name".* ]] || { print -u2 -- "Unsafe staging path"; exit 1; }
app_stage="$stage_root/第五人格启动器.app"
installer_payload="$app_stage/Contents/Resources/InstallerPayload"
temporary_dmg="$stage_root/$release_name.dmg"
temporary_materials="$stage_root/$materials_name.zip"
temporary_checksums="$stage_root/SHA256SUMS.txt"
background_pdf="$stage_root/dmg-background.pdf"
background_generator="$stage_root/make-dmg-background"
materials_listing="$stage_root/materials-entries.txt"
attach_plist="$stage_root/attach.plist"
# Disk Arbitration may refuse an explicit mountpoint located on a removable or
# no-owners data volume even when that volume can hold the finished DMG.  Keep
# artifacts and private staging on the requested output volume, but verify the
# read-only image through a private directory on the system temporary volume.
mount_root="$(/usr/bin/mktemp -d /private/tmp/identityv-alpha1-mount.XXXXXX)"
mounted_device=""

cleanup() {
  if [[ -n "$mounted_device" ]]; then
    /usr/bin/hdiutil detach "$mounted_device" >/dev/null 2>&1 || \
      /usr/bin/hdiutil detach -force "$mounted_device" >/dev/null 2>&1 || true
    mounted_device=""
  fi
  if [[ -n "${stage_root:-}" && "$stage_root" == "$output_root"/.stage-"$release_name".* && -d "$stage_root" ]]; then
    /bin/rm -rf -- "$stage_root"
  fi
  if [[ -n "${mount_root:-}" && "$mount_root" == /private/tmp/identityv-alpha1-mount.* && -d "$mount_root" ]]; then
    /bin/rm -rf -- "$mount_root"
  fi
}
trap cleanup EXIT INT TERM

/usr/bin/ditto "$source_app" "$app_stage"
/usr/bin/xcrun swiftc -O -framework CoreGraphics "$dmg_background_generator" -o "$background_generator"
"$background_generator" "$background_pdf"
[[ "$(/usr/bin/head -c 5 "$background_pdf")" == "%PDF-" ]] || {
  print -u2 -- "DMG background generator did not produce a PDF."
  exit 1
}

[[ -f "$installer_payload/idvLoginComponent.json" && -x "$app_stage/Contents/Resources/IdentityVIdvLoginDownloader" ]] || { print -u2 -- "Missing IDV Login component downloader."; exit 1; }
! /usr/bin/find "$app_stage" \( -iname 'idv-login.raw' -o -iname 'idv-login-v*-mac' \) -print -quit | /usr/bin/grep -q . || { print -u2 -- "Bundled IDV Login binary is forbidden."; exit 1; }

# Fail closed before signing: these belong to upstream downloads or to the game,
# never to an Alpha 1 launcher archive.
typeset -a forbidden_patterns
forbidden_patterns=(
  'DWRG.dmg' 'downloadIPC' 'aria2' 'Orbit' 'dwrg.exe'
  'IdentityV.exe' 'game.exe' 'base runtime' 'base-runtime'
  'idv-login.raw' 'idv-login-v*-mac'
  'IdentityVInputLatencyProbe' 'idv-dense-metrics' 'stopIdentityVMonitoring.command'
)

audit_app_payload() {
  local root="$1" candidate base pattern
  integer forbidden=0
  while IFS= read -r -d '' candidate; do
    base=${candidate:t:l}
    for pattern in "${forbidden_patterns[@]}"; do
      if [[ "$base" == ${~${(L)pattern}}* || "$base" == *${~${(L)pattern}}* ]]; then
        print -u2 -- "Forbidden payload candidate: $candidate"
        (( forbidden += 1 ))
      fi
    done
  done < <(/usr/bin/find "$root" -print0)
  while IFS= read -r -d '' candidate; do
    case "${candidate:e:l}" in
      exe|dll|pak|ucas|utoc) print -u2 -- "Forbidden game-payload extension: $candidate"; (( forbidden += 1 )) ;;
    esac
  done < <(/usr/bin/find "$root" -type f -print0)
  (( forbidden == 0 )) || { print -u2 -- "Payload audit failed ($forbidden finding(s))."; return 1; }
}

audit_app_payload "$app_stage"
"$runtime_patch_audit" "$app_stage"

# Build paths in Mach-O load commands or compiled strings are not needed at
# runtime and must not reveal the maintainer account or workspace. Keep this
# broader than the current username so another release machine fails closed.
if rg -a -l '/Users/[[:alnum:]_.-]+/|codexDaily|/Volumes/Data/Projects/IdentityV Mac' "$app_stage"; then
  print -u2 -- "App payload contains a maintainer/home build path."
  exit 1
fi

# 由内到外签整个发行 App。RuntimePatches 保持字节不变：它们的摘要被
# runtimeBootstrap/runtime-manifest.json、runtimeManifest/runtime-catalog.json 与
# 运行期 runner 三方校验。若未来确需重签，须同步 source/shipped 摘要并处理已装
# runtime 的文件迁移；不能沿用旧字节摘要（见 signing/README.md）。
identityv_sign_bundle_tree "$app_stage"
"$runtime_patch_audit" "$app_stage"
identityv_verify_bundle_tree "$app_stage"

# 先公证 .app 并 staple，再装进 DMG；这样用户离线首次打开时 Gatekeeper 能凭本地
# 票据放行，而不是依赖在线查询公证结果。
if [[ "$IDENTITYV_RESOLVED_KIND" == developer-id ]]; then
  "$project_root/signing/notarizeIdentityV.command" "$app_stage" --profile "$notary_profile"
fi

"$installer_payload/installIdentityVPasswordlessHelpers.command" --verify-only --payload-root "$installer_payload"

IDV_MAX_MACOS_DEPLOYMENT_TARGET=14.0 \
  "$project_root/runtimeManifest/auditMachODeploymentTargets.command" "$app_stage"

"$dmgbuild" -s "$dmg_settings" \
  -D "app=$app_stage" \
  -D "background=$background_pdf" \
  "$release_name" "$temporary_dmg"
/usr/bin/hdiutil verify "$temporary_dmg" >/dev/null
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_root" -plist "$temporary_dmg" > "$attach_plist"
mounted_device="$(/usr/bin/plutil -convert json -o - "$attach_plist" | /usr/bin/jq -r --arg mount "$mount_root" '."system-entities"[] | select(."mount-point" == $mount) | ."dev-entry"' | /usr/bin/head -n 1)"
[[ "$mounted_device" == /dev/* && -d "$mount_root/第五人格启动器.app" ]] || { print -u2 -- "DMG did not mount with the expected app."; exit 1; }

mounted_visible_count="$(/usr/bin/find "$mount_root" -mindepth 1 -maxdepth 1 ! -name '.*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$mounted_visible_count" == 2 && -d "$mount_root/第五人格启动器.app" && -L "$mount_root/Applications" ]] || { print -u2 -- "Mounted DMG visible layout is invalid."; exit 1; }
[[ "$(/usr/bin/readlink "$mount_root/Applications")" == /Applications ]] || { print -u2 -- "Mounted Applications link is invalid."; exit 1; }
[[ -f "$mount_root/.DS_Store" && -f "$mount_root/.background.pdf" ]] || { print -u2 -- "Mounted DMG is missing Finder vector background metadata."; exit 1; }
if /usr/bin/find "$mount_root" -mindepth 1 -maxdepth 1 \( -name '.*' ! -name '.DS_Store' ! -name '.background.pdf' -o -name '__MACOSX' \) -print -quit | /usr/bin/grep -q .; then
  print -u2 -- "Mounted DMG contains unexpected hidden metadata or archive residue."
  exit 1
fi
[[ ! -e "$mount_root/安装说明.md" ]] || { print -u2 -- "The DMG must not contain a separate install guide."; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_root/第五人格启动器.app"
/bin/zsh "$project_root/gameRunnerApp/tests/microphonePrivacyContract.test.command" "$mount_root/第五人格启动器.app"
audit_app_payload "$mount_root/第五人格启动器.app"
"$runtime_patch_audit" "$mount_root/第五人格启动器.app"
IDV_MAX_MACOS_DEPLOYMENT_TARGET=14.0 \
  "$project_root/runtimeManifest/auditMachODeploymentTargets.command" "$mount_root/第五人格启动器.app"

/usr/bin/hdiutil detach "$mounted_device" >/dev/null
mounted_device=""

# Apple 的 DMG Gatekeeper 评估是 `spctl -t open --context
# context:primary-signature`，要求镜像自身有 Developer ID 签名。仅公证并
# staple 未签名 DMG 虽会 Accepted，仍会得到 `source=no usable signature`。
# 在只读挂载复验后签镜像，再公证、staple 并由公证脚本验收 Gatekeeper。
if [[ "$IDENTITYV_RESOLVED_KIND" == developer-id ]]; then
  /usr/bin/codesign --force --sign "$IDENTITYV_RESOLVED_IDENTITY" --timestamp "$temporary_dmg"
  /usr/bin/codesign --verify --verbose=2 "$temporary_dmg"
  "$project_root/signing/notarizeIdentityV.command" "$temporary_dmg" --profile "$notary_profile"
fi

/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$notice_root" "$temporary_materials"
/usr/bin/unzip -tq "$temporary_materials" >/dev/null
/usr/bin/zipinfo -1 "$temporary_materials" > "$materials_listing"
if /usr/bin/grep -Eq '(^|/)__MACOSX(/|$)|(^|/)\.DS_Store$' "$materials_listing"; then
  print -u2 -- "Release materials archive contains macOS metadata."
  exit 1
fi

(
  cd "$stage_root"
  /usr/bin/shasum -a 256 "${temporary_dmg:t}" "${temporary_materials:t}" > "$temporary_checksums"
)

# Publish only after the DMG has been mounted and every artifact has passed.
# The previous known-good release remains in place if any earlier step fails.
/bin/mv -f "$temporary_dmg" "$app_dmg"
/bin/mv -f "$temporary_materials" "$materials_zip"
/bin/mv -f "$temporary_checksums" "$checksums"
if [[ "$IDENTITYV_RESOLVED_KIND" == developer-id ]]; then
  print -- "$release_version 已封包（Developer ID 签名并公证；$IDENTITYV_RESOLVED_IDENTITY）："
else
  print -- "$release_version 已封包（$IDENTITYV_RESOLVED_KIND 签名；未公证）："
fi
print -- "  App disk image: $app_dmg"
print -- "  Notice/source archive: $materials_zip"
print -- "  SHA-256: $checksums"
print -- "  App disk image size: $(/usr/bin/du -sh "$app_dmg" | /usr/bin/awk '{print $1}')"
print -- "  Materials archive size: $(/usr/bin/du -sh "$materials_zip" | /usr/bin/awk '{print $1}')"
