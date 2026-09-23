#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-font-contract.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

[[ -x "$RUNNER" && -x "$AGTK_RUNNER" ]]
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"
/usr/bin/grep -Fqx 'REGISTRY_CONTRACT_VERSION="alpha1-registry-v3"' "$RUNNER"

# Font files and their aliases must be published only after every old process
# serving this prefix is stopped.  Compare the actual main-flow call sites,
# not comments or function declarations.
main_flow="$(/usr/bin/sed -n '/^reset_prefix_if_display_changed$/,/^start_mouse_acceleration_controller$/p' "$RUNNER")"
stop_line="$(print -r -- "$main_flow" | /usr/bin/grep -n -x 'stop_prefix_processes' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
private_line="$(print -r -- "$main_flow" | /usr/bin/grep -n -x 'ensure_private_standard_folders' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
fonts_line="$(print -r -- "$main_flow" | /usr/bin/grep -n '^ensure_prefix_fonts ' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
contract_line="$(print -r -- "$main_flow" | /usr/bin/grep -n '^refresh_registry_contract ' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ "$stop_line" == <-> && "$private_line" == <-> && "$fonts_line" == <-> && "$contract_line" == <-> ]]
(( stop_line < private_line && stop_line < fonts_line && stop_line < contract_line ))

# The selection array is deterministic: first preference is the single-face
# Arial Unicode MS candidate, then only explicit fallbacks.
/usr/bin/grep -Fq 'cjk_sources=(' "$RUNNER"
selection_block="$(/usr/bin/sed -n '/^[[:space:]]*cjk_sources=(/,/^[[:space:]]*cjk_families=/p' "$RUNNER")"
[[ "$(print -r -- "$selection_block" | /usr/bin/grep -m1 '"/System/Library/Fonts')" == *'Supplemental/Arial Unicode.ttf'* ]]
/usr/bin/grep -Fq 'cjk_families=("Arial Unicode MS" "Hiragino Sans GB" "Heiti SC" "Songti SC")' "$RUNNER"

# Execute the runner's real registry-emission function with only a disposable
# prefix and a mocked Wine import.  This validates generated .reg syntax and
# both registry views without invoking Wine or touching the active prefix.
function_source="$(/usr/bin/awk '
  /^refresh_registry_contract\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$RUNNER")"
[[ -n "$function_source" ]] || { print -u2 -- "cannot locate refresh_registry_contract"; exit 1; }
eval "$function_source"

export PREFIX="$TEST_ROOT/prefix"
export LOG_FILE="$TEST_ROOT/runner.log"
export REGISTRY_CONTRACT_VERSION='alpha1-registry-v3'
export SELECTED_ENGINE_ID='font-fixture'
export WINDOWS_GAME_ROOT='IdentityV'
export REGISTRY_CONTRACT_MARKER="$PREFIX/.identityv-launch-registry-contract"
export CJK_UI_FONT_FAMILY='Arial Unicode MS'
export CJK_UI_FONT_FILENAME='Arial Unicode.ttf'
export WINE_BIN='/usr/bin/true'
export CAPTURED_REG="$TEST_ROOT/generated.reg"
/bin/mkdir -p "$PREFIX/drive_c/windows/temp"

run_with_timeout() {
  local seconds="$1"
  shift
  [[ "$seconds" == 12 && "$1" == "$WINE_BIN" && "$2" == reg && "$3" == import ]]
  local generated=("$PREFIX/drive_c/windows/temp"/*.reg(N))
  [[ ${#generated} -eq 1 ]]
  /bin/cp -p "$generated[1]" "$CAPTURED_REG"
  return 0
}

refresh_registry_contract
[[ -f "$CAPTURED_REG" && -f "$REGISTRY_CONTRACT_MARKER" ]]

/usr/bin/grep -q 'HKEY_LOCAL_MACHINE.*CurrentVersion.*Fonts]' "$CAPTURED_REG"
/usr/bin/grep -q 'HKEY_LOCAL_MACHINE.*CurrentVersion.*FontSubstitutes]' "$CAPTURED_REG"
/usr/bin/grep -q 'HKEY_LOCAL_MACHINE.*Wow6432Node.*CurrentVersion.*Fonts]' "$CAPTURED_REG"
/usr/bin/grep -q 'HKEY_LOCAL_MACHINE.*Wow6432Node.*CurrentVersion.*FontSubstitutes]' "$CAPTURED_REG"
/usr/bin/grep -Fqx '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' "$CAPTURED_REG"
/usr/bin/grep -Fqx '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' "$CAPTURED_REG"
[[ "$(/usr/bin/grep -Fxc '"Auto"="1"' "$CAPTURED_REG")" == 2 ]]
[[ "$(/usr/bin/grep -Fxc '"Debugger"=""' "$CAPTURED_REG")" == 2 ]]

# A .reg file emitted by this runner contains only a header, blank lines,
# section headers and quoted string values.  Keep the grammar check narrow so
# malformed quoting cannot be hidden by a successful mock import.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == 'Windows Registry Editor Version 5.00' || "$line" == \[*\] || "$line" == \"*\"=\"*\" ]] || {
    print -u2 -- "invalid generated .reg line: $line"
    exit 1
  }
done < "$CAPTURED_REG"

for name in 'MS Shell Dlg' 'MS Shell Dlg 2' 'Microsoft YaHei' 'Microsoft YaHei UI' 'MicrosoftYaHei' 'SimSun' 'SimHei'; do
  [[ "$(/usr/bin/grep -Fxc "\"$name\"=\"Arial Unicode MS\"" "$CAPTURED_REG")" == 2 ]]
done
[[ "$(/usr/bin/grep -Fxc '"Arial Unicode MS (TrueType)"="Arial Unicode.ttf"' "$CAPTURED_REG")" == 2 ]]

# Exercise the optional engine-bound font using the real selector. A broken
# or redirected candidate must not silently replace the established font.
for function_name in validate_relative_path configure_catalog_cjk_font; do
  function_source="$(/usr/bin/awk -v name="$function_name" '
    $0 == name "() {" { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$RUNNER")"
  [[ -n "$function_source" ]]
  eval "$function_source"
done
CATALOG_FILE="$TEST_ROOT/catalog.json"
fixture_family=''
fixture_filename=''
fixture_hash=''
plist_raw() {
  case "$2" in
    *.cjkFamily) print -r -- "$fixture_family" ;;
    *.cjkFilename) print -r -- "$fixture_filename" ;;
    *.cjkSha256) print -r -- "$fixture_hash" ;;
    *) return 1 ;;
  esac
}
configure_catalog_cjk_font
[[ "$CJK_UI_FONT_FAMILY" == 'Arial Unicode MS' ]]
fixture_family='IdentityV Fixture'
! configure_catalog_cjk_font
fixture_filename='fixture.ttf'
/bin/mkdir -p "$PREFIX/drive_c/windows/Fonts"
print -r -- 'font-integrity-fixture' > "$PREFIX/drive_c/windows/Fonts/$fixture_filename"
fixture_hash="$(/usr/bin/shasum -a 256 "$PREFIX/drive_c/windows/Fonts/$fixture_filename" | /usr/bin/awk '{print $1}')"
configure_catalog_cjk_font
[[ "$CJK_UI_FONT_FAMILY" == "$fixture_family" && "$CJK_UI_FONT_FILENAME" == "$fixture_filename" ]]
refresh_registry_contract
[[ "$(/usr/bin/grep -Fxc '"Microsoft YaHei"="IdentityV Fixture"' "$CAPTURED_REG")" == 2 ]]
print -r -- 'changed' >> "$PREFIX/drive_c/windows/Fonts/$fixture_filename"
! configure_catalog_cjk_font
print -r -- 'font-integrity-fixture' > "$TEST_ROOT/original.ttf"
/bin/rm "$PREFIX/drive_c/windows/Fonts/$fixture_filename"
/bin/ln -s "$TEST_ROOT/original.ttf" "$PREFIX/drive_c/windows/Fonts/$fixture_filename"
! configure_catalog_cjk_font
fixture_filename='../original.ttf'
! configure_catalog_cjk_font
fixture_family=$'bad\nname'
! configure_catalog_cjk_font

print -r -- "Font fallback contract self-test passed"
