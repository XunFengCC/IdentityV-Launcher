#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
build_dir="$script_dir/build"
common_flags=(-mmacosx-version-min=14.0 -std=c11 -Wall -Wextra -Werror)
mkdir -p "$build_dir"

clang "${common_flags[@]}" "$script_dir/policy.c" "$script_dir/policy_test.c" \
  -o "$build_dir/policy_test"
"$build_dir/policy_test"
clang "${common_flags[@]}" "$script_dir/rebinder_filter_protocol.c" "$script_dir/rebinder_filter_protocol_test.c" -o "$build_dir/rebinder_filter_protocol_test"
"$build_dir/rebinder_filter_protocol_test"
clang "${common_flags[@]}" "$script_dir/rebinder_alias_cf_test.c" -framework CoreFoundation -o "$build_dir/rebinder_alias_cf_test"
"$build_dir/rebinder_alias_cf_test"
clang "${common_flags[@]}" "$script_dir/rebinder_filter_protocol.c" "$script_dir/rebinder_alias_translate.c" "$script_dir/rebinder_alias_translate_test.c" -framework CoreAudio -framework CoreFoundation -o "$build_dir/rebinder_alias_translate_test"
"$build_dir/rebinder_alias_translate_test"

typeset -A stages=(
  [load-only]=1
  [passthrough]=2
  [caller]=3
  [filter]=4
  [passthrough-handle]=5
  [rebinder]=6
  [rebinder-filter]=7
  [rebinder-default-alias]=8
)

for stage stage_number in ${(kv)stages}; do
  output="$build_dir/IdentityVCoreAudio-${stage}.dylib"
  sources=("$script_dir/audio_interposer.c")
  extra_defines=()
  [[ "$stage" == rebinder ]] && sources=("$script_dir/import_rebinder.c")
  if [[ "$stage" == rebinder-filter || "$stage" == rebinder-default-alias ]]; then
    sources=("$script_dir/rebinder_filter_protocol.c" "$script_dir/import_rebinder.c")
    extra_defines=(-DIDV_REBINDER_FILTER=1)
    [[ "$stage" == rebinder-default-alias ]] && { sources=("$script_dir/rebinder_filter_protocol.c" "$script_dir/rebinder_alias_translate.c" "$script_dir/import_rebinder.c"); extra_defines+=(-DIDV_REBINDER_ALIAS=1); }
  fi
  [[ "$stage" == filter ]] && sources=("$script_dir/policy.c" "${sources[@]}")
  clang -arch x86_64 "${common_flags[@]}" -dynamiclib \
    -Wl,-install_name,"@rpath/${output:t}" \
    -DIDV_AUDIO_STAGE="$stage_number" "${extra_defines[@]}" -framework CoreAudio -framework CoreFoundation \
    "${sources[@]}" -o "$output"
  codesign --force --sign - "$output"
  # Deliberately grep, not ripgrep: this verifier must run with only the tools a
  # stock macOS ships.  A missing `rg` was being treated as a failed check and
  # silently skipped the static gate, which is worse than a slower match.
  # Deliberately grep, not ripgrep: this verifier must run with only the tools a
  # stock macOS ships.  A missing `rg` used to fail every check and silently
  # skip the whole static gate.  The matcher is a helper because `grep -q`
  # closes the pipe early and `set -o pipefail` would then turn a match into a
  # failure; each grep below reads its input to EOF and prints nothing.
  file "$output" | grep -E x86_64 >/dev/null
  otool -hv "$output" | grep -E X86_64 >/dev/null
  otool -D "$output" | tail -n 1 | grep -F "@rpath/${output:t}" >/dev/null
  codesign --verify --strict --verbose=2 "$output"
  if [[ "$stage" == rebinder || "$stage" == rebinder-filter || "$stage" == rebinder-default-alias ]]; then
    ! otool -l "$output" | grep -E __interpose >/dev/null
    nm -u "$output" | grep -E __dyld_register_func_for_add_image >/dev/null
    nm -u "$output" | grep -F '_AudioObjectGetPropertyData' >/dev/null
    nm -u "$output" | grep -F '_AudioObjectGetPropertyDataSize' >/dev/null
    ! nm -u "$output" | grep -E '_(pthread_once|_dladdr)' >/dev/null
    strings "$output" | grep -F 'IdentityV CoreAudio: rebinder complete' >/dev/null
    strings "$output" | grep -F 'IdentityV CoreAudio: rebinder direct originals ready' >/dev/null
    if [[ "$stage" == rebinder-filter || "$stage" == rebinder-default-alias ]]; then
      nm -u "$output" | grep -E _pthread_key_create >/dev/null
      ! nm -u "$output" | grep -E __tls_get_addr >/dev/null
      strings "$output" | grep -F 'IdentityV CoreAudio: rebinder-filter ready' >/dev/null
      strings "$output" | grep -F 'IdentityV CoreAudio: rebinder-filter narrowed devices' >/dev/null
      strings "$output" | grep -F 'IdentityV CoreAudio: rebinder-filter protocol default observed' >/dev/null
      strings "$output" | grep -F 'IdentityV CoreAudio: rebinder-filter protocol size narrowed' >/dev/null
      strings "$output" | grep -F 'IdentityV CoreAudio: rebinder-filter protocol size fail-closed' >/dev/null
    fi
    if [[ "$stage" == rebinder-default-alias ]]; then
      strings "$output" | grep -F 'IdentityV CoreAudio: alias translated' >/dev/null
      strings "$output" | grep -F 'IdentityV CoreAudio: alias name substituted' >/dev/null
      strings "$output" | grep -F 'IdentityV CoreAudio: alias UID substituted' >/dev/null
    fi
  elif [[ "$stage" == load-only ]]; then
    ! otool -l "$output" | grep -E __interpose >/dev/null
    nm -u "$output" | grep -E _write >/dev/null
    strings "$output" | grep -F 'IdentityV CoreAudio: load-only loaded' >/dev/null
  else
    otool -l "$output" | grep -E __interpose >/dev/null
    strings "$output" | grep -F "IdentityV CoreAudio: ${stage} loaded" >/dev/null
  fi
  if [[ "$stage" == passthrough ]]; then
    ! nm -u "$output" | grep -E '_(dladdr|_strstr)' >/dev/null
  elif [[ "$stage" == caller ]]; then
    nm -u "$output" | grep -E _dladdr >/dev/null
    ! nm "$output" | grep -E 'thread_state|hook_depth' >/dev/null
  elif [[ "$stage" == filter ]]; then
    nm "$output" | grep -E thread_state >/dev/null
  elif [[ "$stage" == passthrough-handle ]]; then
    nm -u "$output" | grep -E _dlopen >/dev/null
    ! nm -u "$output" | grep -E '_(pthread_once|_dladdr)' >/dev/null
    ! strings "$output" | grep -E RTLD_NEXT >/dev/null
    strings "$output" | grep -F 'IdentityV CoreAudio: passthrough-handle resolved' >/dev/null
    strings "$output" | grep -F 'IdentityV CoreAudio: handle no-load missed' >/dev/null
    strings "$output" | grep -F 'IdentityV CoreAudio: handle open fallback succeeded' >/dev/null
  fi
done

"$project_root/runtimeManifest/auditMachODeploymentTargets.command" \
  "$build_dir"/IdentityVCoreAudio-*.dylib \
  "$build_dir/policy_test" \
  "$build_dir/rebinder_filter_protocol_test" \
  "$build_dir/rebinder_alias_cf_test" \
  "$build_dir/rebinder_alias_translate_test"

print 'Built and statically verified eight staged candidates. This script does not run Wine or enumerate audio devices.'
