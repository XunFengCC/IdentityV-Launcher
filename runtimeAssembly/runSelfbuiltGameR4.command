#!/bin/bash
# Explicit maintainer-only runner for the isolated r4 candidate.  It is not a
# product launcher and never reads or changes the active runtime catalog,
# product prefix, installation records, or RC app.
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly ENGINE_ID='wine11-codeweavers-26_1-dxmt-0_80-selfbuilt-gnutls-macos15-r4'
# A maintainer must supply isolated, already verified test paths. No private
# workstation layout or active product runtime is a safe default in a clone.
readonly RUNTIME="${IDENTITYV_R4_RUNTIME:-}"
readonly DEFAULT_PREFIX="${IDENTITYV_R4_PREFIX:-}"
readonly DEFAULT_GAME="$HOME/Library/Application Support/第五人格/CN/game/dwrg.exe"
readonly GAME_D3DCOMPILER_RELATIVE='webviewsupport.cef904430/d3dcompiler_47.dll'
readonly GAME_D3DCOMPILER_SHA256='90401f8b105c1deb070353a93247c74af9e62868e87fdfa71f35a85aae4820ad'
readonly FORWARDER="$(cd "$(dirname "$0")/.." && pwd)/gameRunnerApp/IdentityV-Mac.app/Contents/Resources/IdentityVCommandGraveForwarder.dylib"
readonly LOGIN_HELPER='/Library/PrivilegedHelperTools/identityv-on-mac/start-idv-login.sh'
readonly IDENTITYV_CONFIG_DIR="$HOME/Library/Application Support/IdentityVOnMac"
readonly IDENTITYV_MAINTENANCE_DIR="$IDENTITYV_CONFIG_DIR/Maintenance"
readonly METAL_HUD_CONFIG_FILE="$IDENTITYV_MAINTENANCE_DIR/metal-hud.env"

# Never inherit an old GUI/session HUD into wineboot, wineserver, registry or
# helper calls. The final dwrg.exe command receives a private environment only.
clear_metal_hud_environment() {
  unset MTL_HUD_ENABLED MTL_HUD_LOG_ENABLED MTL_HUD_LOG_SHADER_ENABLED \
    MTL_HUD_CONFIG MTL_HUD_CONFIG_FILE MTL_HUD_DISABLE_MENU_BAR MTL_HUD_ELEMENTS \
    MTL_HUD_OPACITY MTL_HUD_SCALE MTL_HUD_ALIGNMENT MTL_HUD_POSITION_X \
    MTL_HUD_POSITION_Y MTL_HUD_SHOW_METRICS_RANGE MTL_HUD_ENCODER \
    MTL_HUD_ENCODER_TIMING_ENABLED MTL_HUD_ENCODER_TIMING MTL_HUD_INSIGHTS \
    MTL_HUD_INSIGHTS_ENABLED MTL_HUD_REPORT_URL MTL_HUD_SHOW_ZERO_METRICS \
    MTL_HUD_RUSAGE_UPDATE_INTERVAL MTL_HUD_METRIC_TIMEOUT
}
clear_metal_hud_environment

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf 'r4 runner: %s\n' "$*"; }
metal_hud_enabled=0
metal_hud_reason='configuration is absent'

metal_hud_file_is_safe() {
  local owner mode
  [[ -d "$IDENTITYV_CONFIG_DIR" && ! -L "$IDENTITYV_CONFIG_DIR" && -d "$IDENTITYV_MAINTENANCE_DIR" && ! -L "$IDENTITYV_MAINTENANCE_DIR" ]] || return 1
  owner="$(/usr/bin/stat -f '%u' "$IDENTITYV_CONFIG_DIR" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -f '%Lp' "$IDENTITYV_CONFIG_DIR" 2>/dev/null || true)"
  [[ "$owner" == "$(/usr/bin/id -u)" && "$mode" =~ ^[0-9]+$ ]] || return 1
  (( (8#$mode & 8#077) == 0 && (8#$mode & 8#700) == 8#700 )) || return 1
  [[ "$mode" == 700 ]] || return 1
  owner="$(/usr/bin/stat -f '%u' "$IDENTITYV_MAINTENANCE_DIR" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -f '%Lp' "$IDENTITYV_MAINTENANCE_DIR" 2>/dev/null || true)"
  [[ "$owner" == "$(/usr/bin/id -u)" && "$mode" =~ ^[0-9]+$ ]] || return 1
  (( (8#$mode & 8#077) == 0 && (8#$mode & 8#700) == 8#700 )) || return 1
  [[ "$mode" == 700 ]] || return 1
  [[ -f "$METAL_HUD_CONFIG_FILE" && ! -L "$METAL_HUD_CONFIG_FILE" ]] || return 1
  owner="$(/usr/bin/stat -f '%u' "$METAL_HUD_CONFIG_FILE" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -f '%Lp' "$METAL_HUD_CONFIG_FILE" 2>/dev/null || true)"
  [[ "$owner" == "$(/usr/bin/id -u)" && "$mode" =~ ^[0-9]+$ ]] || return 1
  (( (8#$mode & 8#077) == 0 )) || return 1
  case "$mode" in
    400|600) return 0 ;;
    *) return 1 ;;
  esac
}

load_metal_hud_configuration() {
  local raw_line schema_count=0 enabled_count=0 enabled_value='' invalid=0
  metal_hud_enabled=0
  if [[ ! -e "$METAL_HUD_CONFIG_FILE" && ! -L "$METAL_HUD_CONFIG_FILE" ]]; then
    metal_hud_reason='configuration is absent'
    return 0
  fi
  if ! metal_hud_file_is_safe; then
    metal_hud_reason='configuration failed ownership, type or permission checks'
    return 0
  fi
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    [[ "$raw_line" != *$'\r'* && "$raw_line" != *$'\n'* ]] || { invalid=1; break; }
    case "$raw_line" in
      schema=1) schema_count=$((schema_count + 1)) ;;
      enabled=0|enabled=1) enabled_count=$((enabled_count + 1)); enabled_value="${raw_line#enabled=}" ;;
      *) invalid=1; break ;;
    esac
  done < "$METAL_HUD_CONFIG_FILE"
  if (( invalid || schema_count != 1 || enabled_count != 1 )); then
    metal_hud_reason='configuration schema is invalid'
    return 0
  fi
  metal_hud_enabled="$enabled_value"
  metal_hud_reason='configuration accepted'
}
usage() {
  cat <<'EOF'
Usage: runSelfbuiltGameR4.command [--prefix PREFIX] [--game DWRG_EXE] [--winemsync 0|1] --preflight
       runSelfbuiltGameR4.command [--prefix PREFIX] [--game DWRG_EXE] [--winemsync 0|1] --confirm-game-launch

Set IDENTITYV_R4_RUNTIME and IDENTITYV_R4_PREFIX to an existing isolated r4
runtime and prefix before use. The default game is the signed-in user's
mainland game at ~/Library/Application Support/第五人格/CN/game/dwrg.exe.
--preflight is read-only.  A real launch always needs --confirm-game-launch.
EOF
}

prefix="$DEFAULT_PREFIX"
game="$DEFAULT_GAME"
parse_arguments() {
  mode=''
  winemsync='0'
  local winemsync_seen=0
  while (($#)); do
    case "$1" in
      --prefix) (($# >= 2)) || die 'missing value for --prefix'; prefix="$2"; shift 2 ;;
      --game) (($# >= 2)) || die 'missing value for --game'; game="$2"; shift 2 ;;
      --winemsync)
        (($# >= 2)) || die 'missing value for --winemsync'
        (( winemsync_seen == 0 )) || die 'duplicate --winemsync'
        [[ "$2" == 0 || "$2" == 1 ]] || die '--winemsync must be exactly 0 or 1'
        winemsync="$2"
        winemsync_seen=1
        shift 2
        ;;
      --preflight) [[ -z "$mode" ]] || die 'choose exactly one mode'; mode='preflight'; shift ;;
      --confirm-game-launch) [[ -z "$mode" ]] || die 'choose exactly one mode'; mode='launch'; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}
parse_arguments "$@"
[[ -n "$mode" ]] || die 'choose --preflight or --confirm-game-launch'
[[ "$(/usr/bin/id -u)" != 0 ]] || die 'must run in the signed-in user session, never as root'

real_dir() { /bin/realpath "$1" 2>/dev/null; }
sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
inode() { /usr/bin/stat -f '%d:%i' "$1"; }

validate_path_boundary() {
  case "$prefix" in
    "$HOME/Library/Application Support/IdentityVOnMac"/*|"$HOME/Library/Application Support/第五人格"/*)
      die 'refusing a product prefix' ;;
  esac
  [[ "$prefix" = /* && -d "$prefix" && ! -L "$prefix" ]] || die 'prefix must be an existing absolute non-symlink isolated clone'
  [[ "$game" = /* && -f "$game" && ! -L "$game" ]] || die 'game must be an existing absolute non-symlink dwrg.exe'
  [[ "$(real_dir "$prefix")" != '/' ]] || die 'refusing root as prefix'
}

# A directory can satisfy the game inode binding while still be a half-created
# Wine prefix.  Reject that state before any Wine helper, registry import or
# mutable setup.  These structural minima deliberately leave headroom for
# legitimate Wine revisions while separating the verified full clone from the
# 896-file/3-link aborted clone retained as evidence.
validate_prefix_readiness() {
  local file_count link_count hive module
  for hive in system.reg user.reg userdef.reg; do
    [[ -f "$prefix/$hive" && ! -L "$prefix/$hive" ]] || die "isolated prefix readiness failed: missing regular registry hive $hive"
  done
  for module in kernel32.dll ntdll.dll user32.dll advapi32.dll; do
    [[ -f "$prefix/drive_c/windows/system32/$module" && ! -L "$prefix/drive_c/windows/system32/$module" ]] || die "isolated prefix readiness failed: missing regular system32 module $module"
  done
  for module in kernel32.dll ntdll.dll user32.dll; do
    [[ -f "$prefix/drive_c/windows/syswow64/$module" && ! -L "$prefix/drive_c/windows/syswow64/$module" ]] || die "isolated prefix readiness failed: missing regular syswow64 module $module"
  done
  file_count="$(/usr/bin/find "$prefix" -type f -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  link_count="$(/usr/bin/find "$prefix" -type l -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  [[ "$file_count" =~ ^[0-9]+$ && "$link_count" =~ ^[0-9]+$ ]] || die 'isolated prefix readiness failed: could not count structure'
  (( file_count >= 1600 )) || die "isolated prefix readiness failed: only $file_count regular files (minimum 1600)"
  (( link_count >= 8 )) || die "isolated prefix readiness failed: only $link_count symbolic links (minimum 8)"
}

verify_runtime() {
  local manifest expected actual path
  [[ -d "$RUNTIME" && ! -L "$RUNTIME" ]] || die 'r4 runtime is absent or symlinked'
  manifest="$RUNTIME/manifest/manifest.json"
  [[ -f "$manifest" && -f "$RUNTIME/manifest/manifest.sha256" && -f "$RUNTIME/manifest/files.tsv" ]] || die 'r4 manifest is incomplete'
  expected="$(/usr/bin/awk '$2 == "manifest.json" {print $1; exit}' "$RUNTIME/manifest/manifest.sha256")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die 'r4 manifest checksum is malformed'
  actual="$(sha256 "$manifest")"
  [[ "$actual" == "$expected" ]] || die 'r4 manifest checksum mismatch'
  [[ "$(/usr/bin/plutil -extract engineId raw -o - "$manifest" 2>/dev/null)" == "$ENGINE_ID" ]] || die 'r4 manifest engine ID mismatch'
  for path in bin/wine bin/wineserver; do
    expected="$(/usr/bin/awk -F '\t' -v p="$path" '$1 == "file" && $3 == p {print $2; exit}' "$RUNTIME/manifest/files.tsv")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "r4 files manifest lacks $path"
    [[ -x "$RUNTIME/$path" && ! -L "$RUNTIME/$path" ]] || die "r4 executable unavailable: $path"
    actual="$(sha256 "$RUNTIME/$path")"
    [[ "$actual" == "$expected" ]] || die "r4 executable checksum mismatch: $path"
  done
}

validate_binding() {
  local bound="$prefix/drive_c/Games/IdentityV/dwrg.exe"
  [[ -f "$bound" ]] || die 'isolated prefix lacks drive_c/Games/IdentityV/dwrg.exe'
  [[ "$(inode "$bound")" == "$(inode "$game")" ]] || die 'game is not the exact inode bound into this isolated prefix'
}

verify_game_d3dcompiler() {
  game_d3dcompiler="$(dirname "$game")/$GAME_D3DCOMPILER_RELATIVE"
  [[ -f "$game_d3dcompiler" && ! -L "$game_d3dcompiler" ]] || die 'verified game-native 64-bit D3DCompiler is unavailable'
  /usr/bin/file "$game_d3dcompiler" | /usr/bin/grep -Eqi 'PE32\+.*x86-64' || die 'game-native D3DCompiler is not PE32+ x86-64'
  [[ "$(sha256 "$game_d3dcompiler")" == "$GAME_D3DCOMPILER_SHA256" ]] || die 'game-native D3DCompiler hash differs from the verified game component'
}

stage_game_d3dcompiler() {
  local target="$prefix/drive_c/windows/system32/d3dcompiler_47.dll"
  [[ -d "${target%/*}" && ! -L "${target%/*}" ]] || die 'isolated prefix system32 is unavailable or symlinked'
  /bin/cp -f "$game_d3dcompiler" "$target"
  /bin/chmod 644 "$target"
  [[ "$(sha256 "$target")" == "$GAME_D3DCOMPILER_SHA256" ]] || die 'staged game-native D3DCompiler hash mismatch'
}

any_mainland_game_running() {
  /usr/bin/pgrep -u "$(/usr/bin/id -u)" -f 'C:\\Games\\IdentityV\\dwrg[.]exe' >/dev/null 2>&1
}

validate_path_boundary
validate_prefix_readiness
verify_runtime
validate_binding
verify_game_d3dcompiler
if any_mainland_game_running; then
  die 'a mainland dwrg.exe is already running; this isolated runner will not disturb it'
fi

load_metal_hud_configuration
note "Metal HUD: $metal_hud_reason; enabled=$metal_hud_enabled"

if [[ "$mode" == preflight ]]; then
  note "preflight passed: $ENGINE_ID"
  note "prefix: $prefix"
  note "game: $game"
  note "WINEMSYNC: $winemsync"
  exit 0
fi

[[ -f "$FORWARDER" && ! -L "$FORWARDER" ]] || die 'Command+grave forwarder is unavailable'

run_root="${prefix%/prefix}/run-evidence"
[[ "$run_root" == /Volumes/* ]] || die 'evidence must remain beside the isolated external prefix'
/bin/mkdir -p "$run_root" || die 'cannot create isolated run evidence directory'
stamp="$(/bin/date '+%Y%m%d-%H%M%S')"
evidence="$run_root/r4-mainland-$stamp"
/bin/mkdir -p "$evidence" || die 'cannot create run evidence'
log="$evidence/runner.log"
private_host_root="$prefix/private-host-root"
wine="$RUNTIME/bin/wine"
wineserver="$RUNTIME/bin/wineserver"

run_bounded() {
  local seconds="$1" child ticks=0 rc=0 timed_out=0
  shift
  clear_metal_hud_environment
  "$@" >>"$log" 2>&1 & child=$!
  while /bin/kill -0 "$child" 2>/dev/null; do
    if (( ticks >= seconds * 10 )); then
      timed_out=1
      /bin/kill -TERM "$child" 2>/dev/null || true
      /bin/sleep 1
      /bin/kill -KILL "$child" 2>/dev/null || true
      break
    fi
    ticks=$((ticks + 1))
    /bin/sleep 0.1
  done
  wait "$child" 2>/dev/null || rc=$?
  (( timed_out == 0 )) || return 124
  return "$rc"
}

game_child=''
cleanup_done=0
stop_own_child() {
  [[ -n "$game_child" ]] || return 0
  /bin/kill -TERM "$game_child" 2>/dev/null || true
  local i
  for ((i=0; i<20; i++)); do /bin/kill -0 "$game_child" 2>/dev/null || { wait "$game_child" 2>/dev/null || true; return 0; }; /bin/sleep 0.1; done
  /bin/kill -KILL "$game_child" 2>/dev/null || true
  wait "$game_child" 2>/dev/null || true
}
cleanup() {
  (( cleanup_done )) && return 0
  cleanup_done=1
  stop_own_child
  run_bounded 5 /usr/bin/env WINEPREFIX="$prefix" "$wineserver" -k || true
  run_bounded 5 /usr/bin/env WINEPREFIX="$prefix" "$wineserver" -w || true
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export WINEPREFIX="$prefix" WINEARCH=win64 CX_ROOT="$RUNTIME" WINELOADER="$wine" WINESERVER="$wineserver"
export PATH="$RUNTIME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WINEDLLPATH="$RUNTIME/lib/wine:$RUNTIME/lib/dxmt"
export DYLD_FALLBACK_LIBRARY_PATH="$RUNTIME/lib/gnutls/lib:$RUNTIME/lib64:$RUNTIME/lib/wine/x86_64-unix:$RUNTIME/lib/dxmt/x86_64-unix"
export SSL_CERT_FILE='/etc/ssl/cert.pem' QMLSCENE_DEVICE='softwarecontext'
export DOTNET_EnableWriteXorExecute=0 SIM_BACKEND_OVERRIDE=2 ROSETTA_ADVERTISE_AVX=1
# The sealed r4 automated gates and the successful trace-derived visible-game
# baseline both used msync disabled.  Keep the first product-game gate on that
# validated contract; msync is a separate follow-up A/B, not a launch default.
unset WINEMSYNC WINEESYNC DYLD_LIBRARY_PATH
export WINEMSYNC="$winemsync" WINEDLLOVERRIDES='mscoree,mshtml=;d3d9=b;d3d8=b;nvapi,nvapi64,nvngx=d;d3dcompiler_47=n,b'

# Stop only this prefix before its mutable setup.  The running-game guard above
# ensures this cannot be used as a hidden product-game stopper.
run_bounded 5 "$wineserver" -k || true
run_bounded 5 "$wineserver" -w || true
/bin/mkdir -p "$private_host_root" "$prefix/drive_c/windows/Fonts" "$prefix/drive_c/windows/temp"
[[ ! -L "$private_host_root" ]] || die 'private host root must not be a symlink'
zdrive="$prefix/dosdevices/z:"
if [[ -e "$zdrive" || -L "$zdrive" ]]; then
  [[ -L "$zdrive" ]] || die 'refusing to replace a non-symlink Z: drive'
  /bin/rm "$zdrive"
fi
/bin/ln -s "$private_host_root" "$zdrive"

arial='/System/Library/Fonts/Supplemental/Arial Unicode.ttf'
[[ -f "$arial" ]] || die 'Arial Unicode MS source font is unavailable on this Mac'
arial_target="$prefix/drive_c/windows/Fonts/Arial Unicode.ttf"
if [[ ! -f "$arial_target" ]] || ! /usr/bin/cmp -s "$arial" "$arial_target"; then
  # SIP-protected system fonts carry restricted/compressed flags that an
  # ordinary user cannot reproduce on the external test prefix.  Only the
  # verified font bytes are part of this prefix contract; do not preserve
  # ownership, timestamps or filesystem flags.
  /bin/cp -f "$arial" "$arial_target"
  /bin/chmod 644 "$arial_target"
fi

registry_host="$prefix/drive_c/windows/temp/selfbuilt-r4-contract-$$.reg"
registry_win="C:\\windows\\temp\\selfbuilt-r4-contract-$$.reg"
cat >"$registry_host" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\Mac Driver]
"RetinaMode"="Y"
"LeftOptionIsAlt"="N"
"RightOptionIsAlt"="N"
"LeftCommandIsCtrl"="N"
"RightCommandIsCtrl"="N"
"EditMenu"="disabled"
"UsePreciseScrolling"="N"
"UseConfinementCursorClipping"="Y"
"CursorClippingLocksWindows"="Y"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]
"Arial Unicode MS (TrueType)"="Arial Unicode.ttf"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
"MS Shell Dlg"="Arial Unicode MS"
"MS Shell Dlg 2"="Arial Unicode MS"
"Microsoft YaHei"="Arial Unicode MS"
"Microsoft YaHei UI"="Arial Unicode MS"
"MicrosoftYaHei"="Arial Unicode MS"
"SimSun"="Arial Unicode MS"
"SimHei"="Arial Unicode MS"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]
"Auto"="1"
"Debugger"=""

[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\Fonts]
"Arial Unicode MS (TrueType)"="Arial Unicode.ttf"

[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
"MS Shell Dlg"="Arial Unicode MS"
"MS Shell Dlg 2"="Arial Unicode MS"
"Microsoft YaHei"="Arial Unicode MS"
"Microsoft YaHei UI"="Arial Unicode MS"
"MicrosoftYaHei"="Arial Unicode MS"
"SimSun"="Arial Unicode MS"
"SimHei"="Arial Unicode MS"

[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]
"Auto"="1"
"Debugger"=""

[HKEY_CURRENT_USER\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers]
"C:\\Games\\IdentityV\\dwrg.exe"="~ HIGHDPIAWARE"
REG
/bin/chmod 600 "$registry_host"
if ! run_bounded 12 "$wine" reg import "$registry_win"; then
  /bin/rm -f "$registry_host"
  die 'r4 registry contract import failed'
fi
/bin/rm -f "$registry_host"
stage_game_d3dcompiler

inserted="$FORWARDER"
if [[ -x "$LOGIN_HELPER" && ! -L "$LOGIN_HELPER" ]] && [[ "$(/usr/bin/stat -f '%u:%Lp' "$LOGIN_HELPER" 2>/dev/null || true)" == '0:755' ]]; then
  readiness="$(/usr/bin/sudo -n "$LOGIN_HELPER" --status 2>/dev/null | /usr/bin/tail -n 1 || true)"
  if [[ "$readiness" == 'IDV_LOGIN_READINESS=ready' ]]; then
    dns="$(cd "$(dirname "$0")/.." && pwd)/gameRunnerApp/IdentityV-Mac.app/Contents/Resources/IdentityVLoginDNSCompat.dylib"
    [[ -f "$dns" && ! -L "$dns" ]] && inserted="$inserted:$dns"
    printf 'DNS compat enabled after exact helper readiness gate\n' >>"$log"
  fi
fi
export DYLD_INSERT_LIBRARIES="$inserted" WINEDEBUG='-all'
printf 'engine=%s\nprefix=%s\ngame=%s\nmanifest_sha256=%s\nWINEMSYNC=%s\nd3dcompiler_source=%s\nd3dcompiler_sha256=%s\n' "$ENGINE_ID" "$prefix" "$game" "$(sha256 "$RUNTIME/manifest/manifest.json")" "$winemsync" "$game_d3dcompiler" "$GAME_D3DCOMPILER_SHA256" >"$evidence/identity.txt"
build_metal_hud_environment() {
  hud_environment=()
  if [[ "$metal_hud_enabled" != 1 ]]; then
    return 0
  fi
  # Apple exposes no reliable expanded-state variable.  Use a fixed complete
  # first view and keep the menu-bar control out of the player's desktop.
  hud_environment=(
    MTL_HUD_ENABLED=1
    MTL_HUD_DISABLE_MENU_BAR=1
    MTL_HUD_LOG_ENABLED=0
    MTL_HUD_SHOW_METRICS_RANGE=1
    MTL_HUD_SCALE=0.16
    MTL_HUD_ALIGNMENT=topright
    MTL_HUD_ELEMENTS=device,layersize,memory,fps,frameinterval,gputime,presentdelay,frameintervalgraph,fpsgraph
  )
}
build_metal_hud_environment
if [[ "$metal_hud_enabled" == 1 ]]; then
  printf 'metal_hud=enabled-final-child-only\n' >>"$evidence/identity.txt"
else
  printf 'metal_hud=disabled\n' >>"$evidence/identity.txt"
fi
printf 'starting isolated r4 mainland game\n' >>"$log"
cd "$(dirname "$game")"
# Do not use /usr/bin/env here.  SIP strips DYLD_* variables from a system
# executable's environment; Wine needs our DYLD_FALLBACK_LIBRARY_PATH to find
# its bundled FreeType.  This shell child inherits it, exports the HUD only
# for the final game, then execs Wine so $! remains the actual Wine PID.
(
  if ((${#hud_environment[@]})); then
    export "${hud_environment[@]}"
  fi
  exec "$wine" 'C:\Games\IdentityV\dwrg.exe' --start_from_launcher=1 --is_multi_start
) >>"$log" 2>&1 &
game_child=$!
wait "$game_child"
