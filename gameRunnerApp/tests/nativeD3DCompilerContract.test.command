#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-native-d3dcompiler.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"

# Exercise the real reader and policy gate together. macOS 15 plutil can write
# missing-key diagnostics to stdout; a failed extraction must not become data.
plist_source="$(/usr/bin/sed -n '/^plist_raw() {/,/^}/p' "$RUNNER")"
policy_source="$(/usr/bin/sed -n '/^D3DCOMPILER47_POLICY="$(plist_raw /,/^esac$/p' "$RUNNER")"
[[ -n "$plist_source" && -n "$policy_source" ]]
eval "$plist_source"
CATALOG_FILE="$TEST_ROOT/catalog.json"
SELECTED_ENGINE_ID=fixture
print -r -- '{"engines":{"fixture":{"capabilities":{},"label":"valid value"}}}' >| "$CATALOG_FILE"
[[ "$(plist_raw "$CATALOG_FILE" engines.fixture.label)" == 'valid value' ]]
missing_value='sentinel'
if missing_value="$(plist_raw "$CATALOG_FILE" engines.fixture.capabilities.d3dcompiler47Policy)"; then
  print -u2 -- "missing key unexpectedly succeeded"; exit 1
fi
[[ -z "$missing_value" ]]
abort_launcher() { print -u2 -- "$1"; exit 1; }
eval "$policy_source"
[[ -z "$D3DCOMPILER47_POLICY" ]]
print -r -- '{"engines":{"fixture":{"capabilities":{"d3dcompiler47Policy":"verified-game-native-dynamic-only"}}}}' >| "$CATALOG_FILE"
eval "$policy_source"
[[ "$D3DCOMPILER47_POLICY" == verified-game-native-dynamic-only ]]
print -r -- '{"engines":{"fixture":{"capabilities":{"d3dcompiler47Policy":"verified-game-native-when-manifest-present"}}}}' >| "$CATALOG_FILE"
eval "$policy_source"
[[ "$D3DCOMPILER47_POLICY" == verified-game-native-when-manifest-present ]]
print -r -- '{"engines":{"fixture":{"capabilities":{"d3dcompiler47Policy":"unknown-policy"}}}}' >| "$CATALOG_FILE"
if ( eval "$policy_source" ) 2>/dev/null; then
  print -u2 -- "unknown D3DCompiler policy was accepted"; exit 1
fi

# Reproduce the older OS diagnostic stream even on hosts where plutil now
# writes the same error to stderr. Only replace the dependency in this fixture.
mock_plutil() { print -r -- 'Could not extract value: No value at that key path'; return 1; }
eval "${plist_source//\/usr\/bin\/plutil/mock_plutil}"
if missing_value="$(plist_raw "$CATALOG_FILE" missing)"; then
  print -u2 -- "failed extraction unexpectedly succeeded"; exit 1
fi
[[ -z "$missing_value" ]] || { print -u2 -- "failed extraction leaked stdout as a value"; exit 1; }
eval "$policy_source"
[[ -z "$D3DCOMPILER47_POLICY" ]]
eval "$plist_source"

/usr/bin/grep -Fq 'd3dcompiler_47=n,b;winegstreamer=' "$RUNNER"
/usr/bin/grep -Fq '"$D3DCOMPILER47_POLICY" == "verified-game-native-dynamic-only"' "$RUNNER"
/usr/bin/grep -Fq 'engine_patch_check.file' "$RUNNER"
/usr/bin/grep -Fq 'PE32+' "$RUNNER"
/usr/bin/grep -Fq 'Wine system32 target directory is unsafe' "$RUNNER"
/usr/bin/grep -Fq 'Wine system32 target directory escapes the selected prefix' "$RUNNER"
/usr/bin/grep -Fq 'install_verified_native_d3dcompiler' "$RUNNER"

function_source="$(
  /usr/bin/sed -n '/^validate_relative_path() {/,/^}/p' "$RUNNER"
  /usr/bin/sed -n '/^d3dcompiler_file_is_64() {/,/^}/p' "$RUNNER"
  /usr/bin/sed -n '/^native_d3dcompiler_manifest_entry() {/,/^}/p' "$RUNNER"
  /usr/bin/sed -n '/^install_verified_native_d3dcompiler() {/,/^}/p' "$RUNNER"
)"
[[ -n "$function_source" ]] || { print -u2 -- "cannot extract native D3DCompiler functions"; exit 1; }
eval "$function_source"

make_fixture() {
  local name="$1" content="$2" digest_field="${3:-hash}"
  GAME_DIR="$TEST_ROOT/$name/game"
  PREFIX="$TEST_ROOT/$name/prefix"
  LOG_FILE="$TEST_ROOT/$name/runner.log"
  /bin/mkdir -p "$GAME_DIR/webviewsupport.cef904430" "$GAME_DIR/Documents" "$PREFIX/drive_c/windows/system32"
  print -rn -- "$content" >| "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll"
  fixture_size="$(/usr/bin/stat -f '%z' "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll")"
  fixture_digest="$(/sbin/md5 -q "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll")"
  # Minimal de-identified shape of the real upstream manifest: current
  # NetEase files call their 32-hex MD5 field `hash` and include mtime.
  print -r -- "{\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size,\"$digest_field\":\"$fixture_digest\",\"mtime\":1788069462}}" >| "$GAME_DIR/Documents/engine_patch_check.file"
  : >| "$LOG_FILE"
}

# Exercise the same PE descriptor predicate with a mock `file` before the
# installer fixture replaces it (fixtures themselves are deliberately tiny).
MOCK_FILE="$TEST_ROOT/mock-file"
/bin/cat >| "$MOCK_FILE" <<'MOCK'
#!/bin/zsh
case "$2" in
  *32bit*) print -r -- 'PE32 executable (DLL) Intel 80386' ;;
  *nonpe*) print -r -- 'data' ;;
  *) print -r -- 'PE32+ executable (DLL) x86-64' ;;
esac
MOCK
/bin/chmod 700 "$MOCK_FILE"
d3dcompiler_file_is_64() {
  local inspected
  inspected="$($MOCK_FILE -b "$1" 2>/dev/null || true)"
  [[ "$inspected" == *"PE32+"* && "$inspected" == *"x86-64"* ]]
}
d3dcompiler_file_is_64 "$TEST_ROOT/good-pe"
if d3dcompiler_file_is_64 "$TEST_ROOT/32bit" || d3dcompiler_file_is_64 "$TEST_ROOT/nonpe"; then
  print -u2 -- "non-PE64 D3DCompiler was accepted"; exit 1
fi
d3dcompiler_file_is_64() { return 0; }
abort_launcher() { exit 1; }

make_fixture real-upstream-hash 'native-compiler-fixture' hash
# A root-level 32-bit lookalike is deliberately outside the sole permitted
# CEF path and cannot become the source candidate.
print -rn -- 'not-a-64-bit-root-dll' >| "$GAME_DIR/d3dcompiler_47.dll"
LAUNCH_PROFILE=codeweavers-wine-release-dxmt
PRODUCT=mainland
D3DCOMPILER47_POLICY=verified-game-native-dynamic-only
install_verified_native_d3dcompiler
/usr/bin/cmp -s "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll" "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll"
[[ "$(/usr/bin/stat -f '%Lp' "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll")" == 644 ]]
install_verified_native_d3dcompiler # equal target must not be rewritten

make_fixture legacy-md5 'native-compiler-fixture' md5
LAUNCH_PROFILE=codeweavers-wine-release-dxmt
PRODUCT=mainland
install_verified_native_d3dcompiler
/usr/bin/cmp -s "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll" "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll"

make_fixture bad-digest 'native-compiler-fixture' hash
print -r -- "{\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size,\"hash\":\"00000000000000000000000000000000\",\"mtime\":1788069462}}" >| "$GAME_DIR/Documents/engine_patch_check.file"
if ( PRODUCT=mainland; LAUNCH_PROFILE=codeweavers-wine-release-dxmt; install_verified_native_d3dcompiler ); then
  print -u2 -- "bad manifest hash was accepted"; exit 1
fi
[[ ! -e "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ]]

make_fixture bad-size 'native-compiler-fixture'
/usr/bin/sed -i '' 's/"size":[0-9][0-9]*/"size":999999/' "$GAME_DIR/Documents/engine_patch_check.file"
if ( PRODUCT=mainland; LAUNCH_PROFILE=codeweavers-wine-release-dxmt; install_verified_native_d3dcompiler ); then
  print -u2 -- "bad manifest size was accepted"; exit 1
fi
[[ ! -e "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ]]

validate_relative_path 'webviewsupport.cef904430/d3dcompiler_47.dll'
if validate_relative_path '../webviewsupport.cef904430/d3dcompiler_47.dll'; then
  print -u2 -- "path escape was accepted"; exit 1
fi

make_fixture malformed-manifest 'native-compiler-fixture'
print -r -- '{"webviewsupport.cef904430/d3dcompiler_47.dll":"wrong-immediate-value","size":23,"md5":"d1bce130a59663a0f24a0421fb116c30"}' >| "$GAME_DIR/Documents/engine_patch_check.file"
if native_d3dcompiler_manifest_entry "$GAME_DIR/Documents/engine_patch_check.file" 'webviewsupport.cef904430/d3dcompiler_47.dll' >/dev/null; then
  print -u2 -- "manifest key with a non-dict immediate value was accepted"; exit 1
fi
print -r -- "{\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size,\"hash\":\"$fixture_digest\",\"md5\":\"$fixture_digest\"}}" >| "$GAME_DIR/Documents/engine_patch_check.file"
if native_d3dcompiler_manifest_entry "$GAME_DIR/Documents/engine_patch_check.file" 'webviewsupport.cef904430/d3dcompiler_47.dll' >/dev/null; then
  print -u2 -- "manifest entry with both hash and md5 was accepted"; exit 1
fi
print -r -- "{\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size}}" >| "$GAME_DIR/Documents/engine_patch_check.file"
if native_d3dcompiler_manifest_entry "$GAME_DIR/Documents/engine_patch_check.file" 'webviewsupport.cef904430/d3dcompiler_47.dll' >/dev/null; then
  print -u2 -- "manifest entry without a digest was accepted"; exit 1
fi
print -r -- "{\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size,\"hash\":123}}" >| "$GAME_DIR/Documents/engine_patch_check.file"
if native_d3dcompiler_manifest_entry "$GAME_DIR/Documents/engine_patch_check.file" 'webviewsupport.cef904430/d3dcompiler_47.dll' >/dev/null; then
  print -u2 -- "manifest entry with non-string hash was accepted"; exit 1
fi
print -r -- "{\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size,\"hash\":\"abc\"}}" >| "$GAME_DIR/Documents/engine_patch_check.file"
if native_d3dcompiler_manifest_entry "$GAME_DIR/Documents/engine_patch_check.file" 'webviewsupport.cef904430/d3dcompiler_47.dll' >/dev/null; then
  print -u2 -- "manifest entry with a short hash was accepted"; exit 1
fi
print -r -- "{\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size,\"hash\":\"$fixture_digest\"},\"webviewsupport.cef904430/d3dcompiler_47.dll\":{\"size\":$fixture_size,\"hash\":\"$fixture_digest\"}}" >| "$GAME_DIR/Documents/engine_patch_check.file"
if native_d3dcompiler_manifest_entry "$GAME_DIR/Documents/engine_patch_check.file" 'webviewsupport.cef904430/d3dcompiler_47.dll' >/dev/null; then
  print -u2 -- "duplicate manifest keys were accepted"; exit 1
fi

make_fixture multi 'native-compiler-fixture'
/bin/mkdir -p "$GAME_DIR/webviewsupport.cefother"
/bin/cp "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll" "$GAME_DIR/webviewsupport.cefother/d3dcompiler_47.dll"
if ( PRODUCT=mainland; LAUNCH_PROFILE=codeweavers-wine-release-dxmt; install_verified_native_d3dcompiler ); then
  print -u2 -- "multiple DLL candidates were accepted"; exit 1
fi

make_fixture symlink 'native-compiler-fixture'
/bin/mv "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll" "$TEST_ROOT/symlink-source.dll"
/bin/ln -s "$TEST_ROOT/symlink-source.dll" "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll"
if ( PRODUCT=mainland; LAUNCH_PROFILE=codeweavers-wine-release-dxmt; install_verified_native_d3dcompiler ); then
  print -u2 -- "symlinked DLL candidate was accepted"; exit 1
fi

make_fixture parent-link 'native-compiler-fixture'
/bin/rm -rf "$PREFIX/drive_c/windows/system32"
/bin/ln -s "$TEST_ROOT" "$PREFIX/drive_c/windows/system32"
if ( PRODUCT=mainland; LAUNCH_PROFILE=codeweavers-wine-release-dxmt; install_verified_native_d3dcompiler ); then
  print -u2 -- "symlinked system32 parent was accepted"; exit 1
fi

make_fixture middle-link 'native-compiler-fixture'
/bin/rm -rf "$PREFIX/drive_c/windows"
/bin/mkdir -p "$TEST_ROOT/middle-real/system32"
/bin/ln -s "$TEST_ROOT/middle-real" "$PREFIX/drive_c/windows"
if ( PRODUCT=mainland; LAUNCH_PROFILE=codeweavers-wine-release-dxmt; install_verified_native_d3dcompiler ); then
  print -u2 -- "symlinked drive_c/windows chain was accepted"; exit 1
fi

make_fixture global 'native-compiler-fixture'
PRODUCT=global
LAUNCH_PROFILE=codeweavers-wine-release-dxmt
D3DCOMPILER47_POLICY=verified-game-native-dynamic-only
install_verified_native_d3dcompiler
[[ ! -e "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ]]

make_fixture legacy 'native-compiler-fixture'
PRODUCT=mainland
LAUNCH_PROFILE=sikarugir-wswine-dxmt
D3DCOMPILER47_POLICY=verified-game-native-dynamic-only
install_verified_native_d3dcompiler
[[ ! -e "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ]]

# An unknown/legacy catalogue keeps its existing behavior.
make_fixture r1-pristine 'native-compiler-fixture'
/bin/rm -f "$GAME_DIR/Documents/engine_patch_check.file"
PRODUCT=mainland
LAUNCH_PROFILE=codeweavers-wine-release-dxmt
D3DCOMPILER47_POLICY=''
install_verified_native_d3dcompiler
[[ ! -e "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ]]

# r1 first launch can create its manifest without a launch dependency cycle.
# The next launch must install the compiler, rather than skipping it forever.
make_fixture r1-first-launch 'native-compiler-fixture'
/bin/cp "$GAME_DIR/Documents/engine_patch_check.file" "$TEST_ROOT/saved-manifest"
/bin/rm "$GAME_DIR/Documents/engine_patch_check.file"
D3DCOMPILER47_POLICY=verified-game-native-when-manifest-present
install_verified_native_d3dcompiler
[[ ! -e "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ]]
/usr/bin/grep -Fq 'native D3DCompiler deferred:' "$LOG_FILE"
/bin/cp "$TEST_ROOT/saved-manifest" "$GAME_DIR/Documents/engine_patch_check.file"
install_verified_native_d3dcompiler
/usr/bin/cmp -s "$GAME_DIR/webviewsupport.cef904430/d3dcompiler_47.dll" "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll"

make_fixture r1-invalid 'native-compiler-fixture'
print -r -- '{}' >| "$GAME_DIR/Documents/engine_patch_check.file"
if ( install_verified_native_d3dcompiler ); then
  print -u2 -- "r1 invalid manifest was silently deferred"; exit 1
fi
[[ ! -e "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ]]
/bin/rm "$GAME_DIR/Documents/engine_patch_check.file"
/bin/ln -s "$TEST_ROOT/missing-manifest" "$GAME_DIR/Documents/engine_patch_check.file"
if ( install_verified_native_d3dcompiler ); then
  print -u2 -- "r1 dangling manifest symlink was silently deferred"; exit 1
fi

make_fixture r4-missing 'native-compiler-fixture'
/bin/rm "$GAME_DIR/Documents/engine_patch_check.file"
D3DCOMPILER47_POLICY=verified-game-native-dynamic-only
if ( install_verified_native_d3dcompiler ); then
  print -u2 -- "r4 mandatory compiler requirement was weakened"; exit 1
fi

CATALOG_FILE="$PROJECT_ROOT/runtimeManifest/runtime-catalog.json"
SELECTED_ENGINE_ID=wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1
eval "$policy_source"
[[ "$D3DCOMPILER47_POLICY" == verified-game-native-when-manifest-present ]]

print -r -- "native D3DCompiler contract self-test passed"
