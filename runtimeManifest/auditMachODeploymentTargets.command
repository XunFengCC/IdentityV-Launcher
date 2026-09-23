#!/bin/zsh
# Read-only Mach-O deployment-target gate for artifacts we build ourselves.
# Usage: auditMachODeploymentTargets.command [path ...]
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
max_minos=${IDV_MAX_MACOS_DEPLOYMENT_TARGET:-14.0}

if (( $# == 0 )); then
  set -- \
    "$project_root/gameRunnerApp/IdentityV-Mac.app" \
    "$project_root/gameRunnerApp/IdentityV-AGTK.app" \
    "$project_root/.build/launchIdentityV" \
    "$project_root/denseMetrics/idv-dense-metrics" \
    "$project_root/wineAudioInterposer/build"
fi

integer checked=0
integer violations=0
float highest_minos=0.0
highest_minos_display=0.0
typeset -a scan_roots
scan_roots=("$@")

for root in "${scan_roots[@]}"; do
  [[ -e "$root" ]] || { print -u2 -- "Missing audit path: $root"; exit 2; }
  while IFS= read -r -d '' candidate; do
    /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O' || continue
    (( checked += 1 ))
    build_info="$(/usr/bin/xcrun vtool -show-build "$candidate" 2>&1)" || {
      print -u2 -- "Cannot read Mach-O build version: $candidate"
      (( violations += 1 ))
      continue
    }
    typeset -a minos_values
    minos_values=( ${(f)$(print -r -- "$build_info" | /usr/bin/sed -n 's/^[[:space:]]*minos \([0-9][0-9.]*\).*/\1/p')} )
    if (( ${#minos_values} == 0 )); then
      print -u2 -- "No LC_BUILD_VERSION minos found: $candidate"
      (( violations += 1 ))
      continue
    fi
    for minos in "${minos_values[@]}"; do
      if (( minos > highest_minos )); then
        highest_minos=$minos
        highest_minos_display=$minos
      fi
      if (( minos > max_minos )); then
        print -u2 -- "Unsupported deployment target macOS $minos (> $max_minos): $candidate"
        (( violations += 1 ))
      fi
    done
  done < <(/usr/bin/find "$root" -type f -print0)
done

if (( violations > 0 )); then
  print -u2 -- "Deployment target audit failed: $violations violation(s) across $checked Mach-O file(s); highest minos $highest_minos_display."
  exit 1
fi
print -- "Deployment target audit passed: $checked Mach-O file(s), highest minos $highest_minos_display (limit macOS $max_minos)."
