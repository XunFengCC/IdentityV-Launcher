#!/bin/zsh
# Stage and sign the four small, independently redistributable runtime patches
# for a release build.  The large upstream Wine/DMG is intentionally never copied.
#
# 签名与哈希的关系（2026-09-21）：公证要求包内每个 Mach-O 都带 Developer ID 签名
# 与安全时间戳；签了时间戳的产物不可逐字节复现，所以随 App 分发的哈希只能从“已签名
# 的实际产物”生成，不能反过来拿可复现构建去校验。manifest 因此分两个字段：
#   - `sourceSha256`：未签名候选的复现契约，用于校验自产 runtime 候选；
#   - `sha256` 与 catalog 的 verificationFiles：随 App 分发的已签名哈希，由本脚本刷新。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
MANIFEST="$SCRIPT_DIR/runtime-manifest.json"
CATALOG="$PROJECT_ROOT/runtimeManifest/runtime-catalog.json"
CANDIDATE_ROOT="${1:-}"
PAYLOAD_ROOT="${2:-$SCRIPT_DIR/releasePayloads}"

[[ -n "$CANDIDATE_ROOT" && "$CANDIDATE_ROOT" == /* && -d "$CANDIDATE_ROOT" ]] || {
  print -u2 -- "用法：$0 /absolute/runtime-candidate [/absolute/release-payload-cache]"
  exit 64
}
[[ -r "$MANIFEST" && -r "$CATALOG" ]] || { print -u2 -- "缺少 runtime manifest 或 catalog。"; exit 66; }

# 代码签名身份：原因、优先级与边界见 signing/lib/signIdentityV.sh。
source "$PROJECT_ROOT/signing/lib/signIdentityV.sh"
identityv_resolve_identity

# These names are the public patch payload interface.  Target paths are read from
# the shipped manifest, so a candidate from the wrong revision cannot silently
# become a release payload.
typeset -a names=(winemac.so libgmp.10.dylib libpcre2-8.0.dylib libzstd.1.dylib)
typeset -a targets=(lib/wine/x86_64-unix/winemac.so lib64/libgmp.10.dylib lib64/libpcre2-8.0.dylib lib64/libzstd.1.dylib)

if [[ -e "$PAYLOAD_ROOT" && ! -d "$PAYLOAD_ROOT" ]]; then
  print -u2 -- "payload cache 不是目录：$PAYLOAD_ROOT"
  exit 65
fi
/bin/mkdir -p "$PAYLOAD_ROOT"
/bin/chmod 700 "$PAYLOAD_ROOT"

for i in {1..4}; do
  name="${names[$i]}"
  expected_target="${targets[$i]}"
  manifest_target="$(/usr/bin/plutil -extract "patches.$((i-1)).targetRelativePath" raw -o - "$MANIFEST")"
  # 候选是未签名字节：必须对 sourceSha256；字段缺失时退回旧 sha256 以兼容历史 manifest。
  source_hash="$(/usr/bin/plutil -extract "patches.$((i-1)).sourceSha256" raw -o - "$MANIFEST" 2>/dev/null || true)"
  [[ -n "$source_hash" ]] || source_hash="$(/usr/bin/plutil -extract "patches.$((i-1)).sha256" raw -o - "$MANIFEST")"
  [[ "$manifest_target" == "$expected_target" && ${#source_hash} -eq 64 ]] || {
    print -u2 -- "manifest 中的 patch #$i 与 staging 合约不一致"
    exit 65
  }
  source_path="$CANDIDATE_ROOT/$expected_target"
  [[ -f "$source_path" && ! -L "$source_path" ]] || { print -u2 -- "候选缺少常规文件：$expected_target"; exit 66; }
  actual_hash="$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{print $1}')"
  [[ "${actual_hash:l}" == "${source_hash:l}" ]] || { print -u2 -- "候选 hash 不匹配：$expected_target"; exit 65; }
  /usr/bin/install -m 644 "$source_path" "$PAYLOAD_ROOT/$name"
  identityv_codesign "$PAYLOAD_ROOT/$name"
  /usr/bin/codesign --verify --strict "$PAYLOAD_ROOT/$name" || { print -u2 -- "签名校验失败：$name"; exit 74; }
done

# 从已签名的实际产物刷新 manifest 与 catalog 的 shipped 哈希。
/usr/bin/python3 - "$MANIFEST" "$CATALOG" "$PAYLOAD_ROOT" <<'PY'
import hashlib, json, pathlib, sys

manifest_path, catalog_path, payload_root = sys.argv[1:4]
root = pathlib.Path(payload_root)
manifest_file = pathlib.Path(manifest_path)
catalog_file = pathlib.Path(catalog_path)

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

manifest = json.loads(manifest_file.read_text())
replacements = []
for patch in manifest["patches"]:
    new_hash = sha256(root / patch["patchRelativePath"])
    replacements.append((patch["sha256"], new_hash))
    patch["sha256"] = new_hash

# 逐行精确替换，保留原文件的紧凑排版，避免整文件重排产生无关 diff。
# 旧 shipped 哈希在 manifest 里各出现两次（patches 与 finalVerificationFiles），
# 在 catalog 里只出现在三个 alpha1-r1 engine 上；r4 用的是自建文件、值不同，不受影响。
def rewrite(text, pairs):
    lines = []
    for line in text.splitlines(keepends=True):
        for old, new in pairs:
            if old in line and old != new:
                line = line.replace('"%s"' % old, '"%s"' % new)
        lines.append(line)
    return "".join(lines)

manifest_text = rewrite(manifest_file.read_text(), replacements)
manifest_file.write_text(manifest_text)

catalog_text = rewrite(catalog_file.read_text(), replacements)
catalog_file.write_text(catalog_text)

for name, (old, new) in zip((p["patchRelativePath"] for p in manifest["patches"]), replacements):
    print("  %-24s %s -> %s" % (name, old[:12], new[:12]))
PY

print -- "已核验、签名并刷新哈希：$PAYLOAD_ROOT"
