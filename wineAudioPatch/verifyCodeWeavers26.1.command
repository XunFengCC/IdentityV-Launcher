#!/bin/zsh
# Rebase and compile-check only. This never modifies an installed Wine runtime,
# a prefix, a launcher, or an application bundle.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
archive="${CROSSOVER_SOURCE_ARCHIVE:-}"
expected_archive_sha='e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa'
expected_coreaudio_sha='635347dcfc86800ed64737c6487a808836240e7846c6af699493e7a683d3f42c'
build_root="${IDV_WINE_AUDIO_BUILD_ROOT:-$script_dir/build-26.1/rebuild-$(date +%Y%m%dT%H%M%S)}"
bison_bin="${BISON:-$script_dir/build-26.1/deps/bison-3.8.2-prefix/bin/bison}"

if [[ -z "$archive" || ! -f "$archive" ]]; then
  print -u2 'set CROSSOVER_SOURCE_ARCHIVE to the verified CodeWeavers 26.1 source archive'
  exit 2
fi
if [[ ! -x "$bison_bin" ]]; then
  print -u2 "Bison >= 3.0 is required; no isolated Bison found at: $bison_bin"
  exit 2
fi
if [[ -e "$build_root" ]]; then
  print -u2 "refusing to reuse build root: $build_root"
  exit 2
fi

actual_archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_archive_sha" == "$expected_archive_sha" ]] || {
  print -u2 "source archive SHA-256 mismatch: $actual_archive_sha"
  exit 3
}

mkdir -p "$build_root/source"
tar -xzf "$archive" -C "$build_root/source" --strip-components=2 sources/wine
source_dir="$build_root/source"
actual_coreaudio_sha="$(shasum -a 256 "$source_dir/dlls/winecoreaudio.drv/coreaudio.c" | awk '{print $1}')"
[[ "$actual_coreaudio_sha" == "$expected_coreaudio_sha" ]] || {
  print -u2 "CoreAudio source SHA-256 mismatch: $actual_coreaudio_sha"
  exit 3
}

patch --dry-run -d "$source_dir" -p1 < "$script_dir/default-input-only.patch"
patch -d "$source_dir" -p1 < "$script_dir/default-input-only.patch"
grep -Fq 'devices[0] = default_id' "$source_dir/dlls/winecoreaudio.drv/coreaudio.c"
grep -Fq 'default_id == kAudioObjectUnknown' "$source_dir/dlls/winecoreaudio.drv/coreaudio.c"
awk '
  /if\(params->flow == eCapture\)\{/{capture=1; seen=1; next}
  capture && /^    else\{/{capture=0}
  capture && /kAudioHardwarePropertyDevices/{bad=1}
  END { exit (!seen || bad) }
' "$source_dir/dlls/winecoreaudio.drv/coreaudio.c" || {
  print -u2 'Capture branch still reaches kAudioHardwarePropertyDevices'
  exit 4
}

# This is deliberately a native arm64 Unix-library compile check. The shipped
# module is x86_64, but this host has neither the required x86_64 PE compiler
# nor x86_64 32-bit development libraries. It validates the exact CodeWeavers
# source and all CoreAudio translation units without pretending to produce a
# deployable replacement.
(
  cd "$source_dir"
  PATH="$(dirname "$bison_bin"):$PATH" BISON="$bison_bin" ./configure \
    --enable-archs=none --without-mingw --disable-tests --without-x \
    --without-gstreamer --without-vulkan >"$build_root/configure.log" 2>&1
  PATH="$(dirname "$bison_bin"):$PATH" BISON="$bison_bin" make \
    dlls/winecoreaudio.drv/winecoreaudio.so >"$build_root/winecoreaudio-build.log" 2>&1
)

module="$source_dir/dlls/winecoreaudio.drv/winecoreaudio.so"
[[ -f "$module" ]] || {
  print -u2 "build finished without expected module: $module"
  exit 4
}
file "$module"
otool -L "$module"
shasum -a 256 "$module"
print 'PASS: isolated native-arm64 CodeWeavers 26.1 CoreAudio compile-check complete.'
print 'NOT DEPLOYABLE: an x86_64 release build additionally needs the original PE toolchain, 32-bit development libraries, full configure flags, and release signing.'
