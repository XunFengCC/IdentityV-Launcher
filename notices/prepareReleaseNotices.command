#!/bin/zsh
# Build Alpha 1's redistributable notice/source material from the locked TSV.
# It writes only notices/.build, never stages the upstream base runtime or game.
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
manifest="$script_dir/releaseMaterialsManifest.tsv"
output_root="$script_dir/.build"
stage="$output_root/ReleaseMaterials.stage"
final="$output_root/ReleaseMaterials"

[[ -r "$manifest" ]] || { print -u2 -- "missing manifest: $manifest"; exit 66; }
[[ -r "$project_dir/LICENSE" ]] || { print -u2 -- "missing project license: $project_dir/LICENSE"; exit 66; }

# The version in the App's component lock and the provenance in ReleaseMaterials
# drifted apart once (6.3.0 runtime versus 6.2.3 license URL). Check the two
# independent locks before downloading, so a future update fails loudly.
idv_component="$project_dir/idvLoginComponent.json"
idv_version="$(/usr/bin/plutil -extract version raw -o - "$idv_component")"
idv_release_tag="$(/usr/bin/plutil -extract releaseTag raw -o - "$idv_component")"
idv_source_commit="389d23a7763fe9e5985cb77a3114b8c4dcb670e1"
idv_license_path="ThirdPartyNotices/licenses/idv-login-GPL-3.0-or-later.txt"
idv_license_url="$(/usr/bin/awk -F '\t' -v name="$idv_license_path" '$2 == name {print $3}' "$manifest")"
idv_license_purpose="$(/usr/bin/awk -F '\t' -v name="$idv_license_path" '$2 == name {print $7}' "$manifest")"
[[ "$idv_release_tag" == "v${idv_version}-stable" &&
   "$idv_license_url" == "https://raw.githubusercontent.com/KKeygen/idv-login/$idv_source_commit/LICENSE" &&
   "$idv_license_purpose" == "idv-login $idv_version stable "* ]] || {
  print -u2 -- "idv-login App lock, license source and release material version disagree."
  exit 65
}

safe_relpath() {
  [[ "$1" != /* && "$1" != *'..'* && "$1" != *'//' && -n "$1" ]]
}

host_allowed() {
  local url="$1" allowed="$2" remainder host candidate
  [[ "$url" == https://* ]] || return 1
  remainder="${url#https://}"
  host="${remainder%%/*}"
  [[ "$host" != *:* && -n "$host" ]] || return 1
  for candidate in ${(s:,:)allowed}; do
    [[ "$host" == "$candidate" ]] && return 0
  done
  return 1
}

verify_redirect_chain() {
  local url="$1" allowed="$2" header location
  host_allowed "$url" "$allowed" || return 1
  header="$(/usr/bin/curl --http1.1 --fail --silent --show-error --head --location --max-redirs 5 \
    --retry 5 --retry-all-errors --retry-delay 1 --connect-timeout 20 --max-time 180 \
    --proto '=https' --proto-redir '=https' "$url")" || return 1
  while IFS= read -r location; do
    location="${location#$'\r'}"
    [[ -z "$location" ]] && continue
    [[ "$location" == https://* ]] || return 1
    host_allowed "$location" "$allowed" || return 1
  done <<<"$(print -r -- "$header" | /usr/bin/sed -n 's/^[Ll]ocation: //p' | /usr/bin/tr -d '\r')"
}

download_locked() {
  local relative="$1" url="$2" allowed="$3" max_bytes="$4" expected_sha="$5"
  local destination="${stage}/${relative}" actual_sha byte_count effective_url
  safe_relpath "$relative" || { print -u2 -- "unsafe material path: $relative"; return 1; }
  [[ "$max_bytes" == <-> && "$max_bytes" -gt 0 && "$expected_sha" =~ '^[0-9A-Fa-f]{64}$' ]] || {
    print -u2 -- "invalid size/hash lock: $relative"; return 1
  }
  verify_redirect_chain "$url" "$allowed" || { print -u2 -- "unsafe redirect host: $url"; return 1; }
  /bin/mkdir -p "${destination:h}"
  effective_url="$(/usr/bin/curl --http1.1 --fail --silent --show-error --location --max-redirs 5 \
    --retry 5 --retry-all-errors --retry-delay 1 --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 900 --output "$destination" --write-out '%{url_effective}' "$url")"
  host_allowed "$effective_url" "$allowed" || { print -u2 -- "unsafe final host: $effective_url"; return 1; }
  [[ ! -L "$destination" && -f "$destination" ]] || { print -u2 -- "not a regular material file: $relative"; return 1; }
  byte_count="$(/usr/bin/stat -f '%z' "$destination")"
  (( byte_count > 0 && byte_count <= max_bytes )) || { print -u2 -- "material size exceeds lock: $relative ($byte_count > $max_bytes)"; return 1; }
  actual_sha="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
  [[ "${actual_sha:l}" == "${expected_sha:l}" ]] || { print -u2 -- "SHA-256 mismatch: $relative"; return 1; }
}

# Recreate only this ignored staging directory.  Final is replaced atomically.
/bin/rm -rf "$stage"
/bin/mkdir -p "$stage/ProjectLicense" "$stage/ThirdPartyNotices/licenses" "$stage/CorrespondingSources"
/bin/chmod 700 "$stage"

while IFS=$'\t' read -r group relative url allowed max_bytes sha purpose; do
  [[ -z "$group" || "$group" == \#* ]] && continue
  [[ "$group" == source || "$group" == license ]] || { print -u2 -- "unknown manifest group: $group"; exit 65; }
  download_locked "$relative" "$url" "$allowed" "$max_bytes" "$sha"
done < "$manifest"

# Source archives carry the primary BSD/GPL-or-LGPL texts. idv-login's GPL text
# is fetched as its own locked license entry: the upstream complete codeload
# archive is intentionally not repackaged because it includes Windows binaries
# whose redistribution terms are not established for this project.
tar -xOf "$stage/CorrespondingSources/GMP/gmp-6.3.0.tar.xz" 'gmp-6.3.0/COPYING.LESSERv3' > "$stage/ThirdPartyNotices/licenses/GMP-LGPL-3.0-or-later.txt"
tar -xOf "$stage/CorrespondingSources/PCRE2/pcre2-10.47.tar.bz2" 'pcre2-10.47/LICENCE.md' > "$stage/ThirdPartyNotices/licenses/PCRE2-BSD-3-Clause.txt"
tar -xOf "$stage/CorrespondingSources/zstd/zstd-1.5.7.tar.zst" 'zstd-1.5.7/LICENSE' > "$stage/ThirdPartyNotices/licenses/zstd-BSD-or-GPL-2.0.txt"

/bin/cp "$script_dir/releaseMaterialsManifest.tsv" "$stage/ThirdPartyNotices/releaseMaterialsManifest.tsv"
/bin/cp "$script_dir/THIRD_PARTY_STATUS.md" "$stage/ThirdPartyNotices/THIRD_PARTY_STATUS.md"
/bin/cp "$project_dir/LICENSE" "$stage/ProjectLicense/GPL-3.0-or-later.txt"
/bin/cp "$project_dir/wineMousePatch/eefbbc07-ClipCursor-reset.patch" "$stage/CorrespondingSources/Wine-ClipCursor-patch-eefbbc07.patch"
/bin/cp "$project_dir/runtimeBootstrap/stageRuntimePatchPayloads.command" "$stage/CorrespondingSources/stageRuntimePatchPayloads.command"
/bin/cp "$project_dir/runtimeBootstrap/runtime-manifest.json" "$stage/CorrespondingSources/runtime-manifest.json"

cat > "$stage/ProjectLicense/README.md" <<'EOF'
# 第五人格启动器项目许可证

本项目原创的启动器、工具箱、helper 与相关源代码采用
GPL-3.0-or-later。随附的 `GPL-3.0-or-later.txt` 是完整许可证原文。

Wine/yanyun 衍生补丁、第三方组件、游戏资源和 idv-login 不因本项目
根许可证而改变许可；它们继续按 `ThirdPartyNotices/` 和对应源码目录中
记录的各自许可证、来源与分发边界处理。

本材料包主要承载第三方 notice 与对应源码，并不单独构成启动器的完整
对应源码。向任何受邀者或公众分发启动器二进制时，必须在同一发行位置
另行提供与该二进制精确匹配的项目源码归档或公开 Git tag。
EOF

cat > "$stage/CorrespondingSources/Wine-CodeWeavers-source-offer.txt" <<'EOF'
Wine / CodeWeavers source offer for the four small RC1 runtime replacement payloads

This release does NOT contain DWRG.dmg or the CodeWeavers base runtime.  It contains
only a locally rebuilt winemac.so plus locally rebuilt GMP, PCRE2, and zstd dylibs.

The complete CodeWeavers source archive is included at
CorrespondingSources/Wine/crossover-sources-26.1.0.tar.gz and is also available from:
https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz
Exact archive size: 149051164 bytes
SHA-256: e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa
Wine code used: sources/wine from that archive; build target wine 11 / CodeWeavers 26.1.
Modification: Wine upstream commit eefbbc07a838ffc9e71a963fa3aec14c9cb5a1a2,
included here as Wine-ClipCursor-patch-eefbbc07.patch.
Build recipe: buildWine11ClipCursorRuntime-Alpha1.recipe, with
MACOSX_DEPLOYMENT_TARGET=14.0 and CC="clang -arch x86_64".

For Wine/GMP/PCRE2/zstd, complete corresponding source archives are included in
this CorrespondingSources directory. The intended build ABI is x86_64 macOS 14.0:
clang -arch x86_64 -mmacosx-version-min=14.0 / MACOSX_DEPLOYMENT_TARGET=14.0.
The runtime manifest records the exact resulting payload SHA-256 values.

LGPL fulfillment note: recipients may replace or relink the LGPL-covered Wine/GMP
portions; no signed-hardware lock prevents doing so.  The base runtime is acquired
directly from its upstream publisher and is outside this package's redistribution.
EOF

cat > "$stage/CorrespondingSources/idv-login-source-acquisition.txt" <<EOF
idv-login $idv_version stable source acquisition notice

This RC1 material set does not contain idv-login's codeload source archive.
At the referenced commit, that archive contains Windows payloads including
downloadIPC.exe, OrbitSDK.dll, aria2c.exe, mpay.dll, and a nested downloadIPC.zip.
Their licenses and redistribution permission have not been established for this
project, so redistributing that archive would contradict this release boundary.

Upstream project: https://github.com/KKeygen/idv-login
Release tag: https://github.com/KKeygen/idv-login/releases/tag/$idv_release_tag
Exact source commit: https://github.com/KKeygen/idv-login/tree/$idv_source_commit
Exact upstream source archive (obtained directly from upstream, not repackaged
by this project):
https://codeload.github.com/KKeygen/idv-login/tar.gz/$idv_source_commit

The GPL-3.0-or-later license text for the upstream project is included at:
ThirdPartyNotices/licenses/idv-login-GPL-3.0-or-later.txt

This notice is not a claim that bundling the upstream macOS idv-login binary is
fully compliant.  The RC1 launcher must either obtain that binary directly
from the upstream release and verify it, or complete a separate audit of its
PyInstaller/PyQt/Qt closure, notices, source obligations, and exact hash.
EOF

cat > "$stage/CorrespondingSources/buildWine11ClipCursorRuntime-Alpha1.recipe" <<'EOF'
#!/bin/zsh
# Reproducible recipe for the Alpha 1 winemac.so replacement. Set
# CROSSOVER_SOURCE_ARCHIVE to the checked CodeWeavers 26.1 source archive.
set -euo pipefail
archive="${CROSSOVER_SOURCE_ARCHIVE:?set an absolute source archive path}"
work="${IDV_WINE_BUILD_ROOT:?set an empty absolute build directory}"
patch_file="${IDV_CLIPCURSOR_PATCH:?set the included patch path}"
[[ -f "$archive" && ! -L "$archive" && "$work" == /* && "$patch_file" == /* ]] || exit 64
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa ]] || exit 65
mkdir -p "$work/source"
tar -xzf "$archive" -C "$work/source" --strip-components=2 sources/wine
patch --dry-run -d "$work/source" -p1 < "$patch_file"
patch -d "$work/source" -p1 < "$patch_file"
cd "$work/source"
export CC="clang -arch x86_64"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-mmacosx-version-min=14.0 -DSONAME_LIBVULKAN=\"libMoltenVK.dylib\" -include sys/sysctl.h"
./configure --enable-archs=none --without-mingw --disable-tests --without-x --without-gstreamer --without-vulkan --without-freetype
make dlls/winemac.drv/winemac.so
EOF

cat > "$stage/ThirdPartyNotices/GO_MODULES.txt" <<'EOF'
Actual non-standard Go modules compiled into the RC1 native helpers

IdentityVDownloadSupervisor (gameDownloader):
  github.com/go-zeromq/zmq4 v0.17.0 — BSD-3-Clause
  golang.org/x/sync v0.7.0 — BSD-3-Clause
  golang.org/x/text v0.15.0 — BSD-3-Clause
IdentityVManifestPlanner (manifestPlanner):
  github.com/cespare/xxhash/v2 v2.3.0 — MIT
IdentityVGlobalAdapter (globalAdapter):
  github.com/cespare/xxhash/v2 v2.3.0 — MIT
IdentityVRuntimeBootstrap (runtimeBootstrap): standard library only
IdentityVDownloaderCoreBootstrap (downloaderCoreBootstrap): standard library only

This list was checked with `go list -deps` for all five helper modules.  The indirect
goczmq/v4 module is not in the compiled dependency graph and is therefore not listed.
EOF

find "$stage" -type l -print -quit | /usr/bin/grep -q . && { print -u2 -- "refusing symlink in release materials"; exit 65; }
find "$stage" ! -type d ! -type f -print -quit | /usr/bin/grep -q . && { print -u2 -- "refusing non-regular release material"; exit 65; }

forbidden_payload_name() {
  local candidate="${1:t:l}"
  # Match the actual prohibited payload basenames/prefixes.  Do not use broad
  # substrings: Wine/GStreamer legitimately contains names such as
  # gstrtpgsmpay.h (GSM payloader), which is unrelated to NetEase mpay.dll.
  [[ "$candidate" == downloadipc* || "$candidate" == orbitsdk* || "$candidate" == aria2c* || "$candidate" == mpay* || "$candidate" == dwrg* || "$candidate" == 'identityv.exe' || "$candidate" == 'game.exe' || "$candidate" == *.pak || "$candidate" == *.ucas || "$candidate" == *.utoc ]]
}

# Inspect release materials and all nested ZIP/TAR-family archives by member
# name.  Nested archives are unpacked only into the private staging tree.  A
# match is a release failure, not a warning: notices must never smuggle game or
# unlicensed download payloads through a source archive.
audit_archive_members() {
  local archive="$1" label="$2" member nested index=0 child
  local -a members
  case "${archive:l}" in
    *.zip) members=("${(@f)$(/usr/bin/unzip -Z1 "$archive")}") ;;
    *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.tar.zst)
      members=("${(@f)$(/usr/bin/bsdtar -tf "$archive")}") ;;
    *) return 0 ;;
  esac
  for member in "${members[@]}"; do
    [[ -n "$member" ]] || continue
    forbidden_payload_name "${member:t}" && { print -u2 -- "forbidden payload in archive $label: $member"; return 1; }
    case "${member:l}" in
      *.zip|*.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.tar.zst)
        (( index += 1 ))
        child="$stage/.archive-audit/${label//[^A-Za-z0-9]/_}-$index-${member:t}"
        /bin/mkdir -p "${child:h}"
        case "${archive:l}" in
          *.zip) /usr/bin/unzip -p "$archive" "$member" > "$child" ;;
          *) /usr/bin/bsdtar -xOf "$archive" "$member" > "$child" ;;
        esac
        [[ -s "$child" && ! -L "$child" ]] || { print -u2 -- "cannot inspect nested archive: $label:$member"; return 1; }
        audit_archive_members "$child" "$label:$member" || return 1
        ;;
    esac
  done
}

while IFS= read -r -d '' candidate; do
  forbidden_payload_name "${candidate:t}" && { print -u2 -- "forbidden payload in release materials: $candidate"; exit 65; }
  audit_archive_members "$candidate" "${candidate#$stage/}" || exit 65
done < <(/usr/bin/find "$stage" -type f -print0)
/bin/rm -rf "$stage/.archive-audit"
if /usr/bin/grep -RInE '/Users/|/Volumes/|Authorization:|Bearer |token=|session=' "$stage"; then
  print -u2 -- "refusing machine path or probable secret in release material"
  exit 65
fi
(cd "$stage" && /usr/bin/find . -type f ! -name SHA256SUMS -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256) > "$stage/SHA256SUMS"
/bin/chmod -R go-w "$stage"
/bin/rm -rf "$final"
/bin/mv "$stage" "$final"
print -- "Release notice materials ready: $final"
