#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
build_dir="$script_dir/build"
source_file="$script_dir/dns_import_rebinder.c"
output="$build_dir/IdentityVLoginDNSCompat.dylib"
probe="$build_dir/identityv-dns-probe"
fixture="$build_dir/ws2_32.so"
typeset -a common_flags
common_flags=(-mmacosx-version-min=14.0 -O2 -Wall -Wextra -Werror)

/bin/mkdir -p "$build_dir"
/usr/bin/xcrun --sdk macosx clang -arch x86_64 "${common_flags[@]}" -dynamiclib \
  -Wl,-install_name,@rpath/IdentityVLoginDNSCompat.dylib \
  "$source_file" -o "$output"
/usr/bin/codesign --force --sign - --identifier com.xunfeng.identityv.login-dns-compat "$output"
/usr/bin/codesign --verify --strict --verbose=2 "$output"
/usr/bin/file "$output" | /usr/bin/grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
/usr/bin/nm -u "$output" | /usr/bin/grep -q '_getaddrinfo'
/usr/bin/nm -u "$output" | /usr/bin/grep -q '_gethostbyname'
! /usr/bin/otool -l "$output" | /usr/bin/grep -q '__interpose'

/usr/bin/xcrun --sdk macosx clang -arch x86_64 "${common_flags[@]}" \
  "$script_dir/dns_probe.c" -o "$probe" -ldl
/usr/bin/xcrun --sdk macosx clang -arch x86_64 "${common_flags[@]}" -dynamiclib \
  -Wl,-no_fixup_chains,-install_name,@rpath/ws2_32.so \
  "$script_dir/dns_fixture.c" -o "$fixture"
/usr/bin/codesign --force --sign - --identifier com.xunfeng.identityv.login-dns-fixture "$fixture"
/usr/bin/codesign --force --sign - --identifier com.xunfeng.identityv.login-dns-probe "$probe"

probe_output="$(/usr/bin/arch -x86_64 /usr/bin/env DYLD_INSERT_LIBRARIES="$output" "$probe" "$fixture" 2>&1)"
print -r -- "$probe_output"
print -r -- "$probe_output" | /usr/bin/grep -q 'IdentityV login DNS: target imports ready'
print -r -- "$probe_output" | /usr/bin/grep -q 'IdentityV login DNS: mapped managed domain to local proxy'
print -r -- "$probe_output" | /usr/bin/grep -q '^managed_getaddrinfo=127\.0\.0\.1$'
print -r -- "$probe_output" | /usr/bin/grep -q '^managed_gethostbyname=127\.0\.0\.1$'
if print -r -- "$probe_output" | /usr/bin/grep -q '^unmanaged_getaddrinfo=127\.0\.0\.1$'; then
  print -u2 -- 'unmanaged DNS was unexpectedly redirected'
  exit 1
fi

print -r -- "Identity V login DNS compatibility candidate verified: $output"
