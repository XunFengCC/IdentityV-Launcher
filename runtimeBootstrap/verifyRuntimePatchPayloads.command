#!/bin/zsh
# Verify that the four byte-locked runtime patches still match the manifest.
# These Mach-O files are resources copied into a downloaded runtime; signing
# them again after the manifest is generated changes their bytes and must fail.
set -euo pipefail

(( $# == 1 )) || { print -u2 -- "用法：${0:t} APP_PATH"; exit 64; }
app_path=${1:A}
resources="$app_path/Contents/Resources"
manifest="$resources/runtime-manifest.json"
patch_root="$resources/RuntimePatches"

[[ -d "$app_path" && -f "$manifest" && ! -L "$manifest" && -d "$patch_root" && ! -L "$patch_root" ]] || {
  print -u2 -- "runtime patch audit input is incomplete"
  exit 65
}

manifest_json="$(/usr/bin/plutil -convert json -o - "$manifest")"
[[ "$(print -r -- "$manifest_json" | /usr/bin/jq -r '.schemaVersion // 0')" == 1 ]] || {
  print -u2 -- "runtime patch manifest schema is invalid"
  exit 65
}

typeset -A seen
integer count=0
while IFS=$'\t' read -r relative expected_hash; do
  [[ -n "$relative" && -n "$expected_hash" ]] || continue
  case "$relative" in
    winemac.so|libgmp.10.dylib|libpcre2-8.0.dylib|libzstd.1.dylib) ;;
    *) print -u2 -- "unexpected runtime patch in manifest: $relative"; exit 65 ;;
  esac
  [[ -z "${seen[$relative]:-}" ]] || { print -u2 -- "duplicate runtime patch: $relative"; exit 65; }
  [[ ${#expected_hash} -eq 64 && "$expected_hash" != *[^0-9A-Fa-f]* ]] || {
    print -u2 -- "invalid runtime patch hash: $relative"
    exit 65
  }
  target="$patch_root/$relative"
  [[ -f "$target" && ! -L "$target" ]] || { print -u2 -- "runtime patch is not a regular file: $relative"; exit 65; }
  actual_hash="$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')"
  [[ "${actual_hash:l}" == "${expected_hash:l}" ]] || {
    print -u2 -- "runtime patch hash mismatch: $relative"
    exit 65
  }
  seen[$relative]=1
  (( count += 1 ))
done <<< "$(print -r -- "$manifest_json" | /usr/bin/jq -r '.patches[] | [.patchRelativePath, .sha256] | @tsv')"

(( count == 4 )) || { print -u2 -- "runtime patch count mismatch: $count"; exit 65; }
for required in winemac.so libgmp.10.dylib libpcre2-8.0.dylib libzstd.1.dylib; do
  [[ "${seen[$required]:-}" == 1 ]] || { print -u2 -- "missing runtime patch: $required"; exit 65; }
done

print -- "Runtime patch manifest/hash audit passed."
