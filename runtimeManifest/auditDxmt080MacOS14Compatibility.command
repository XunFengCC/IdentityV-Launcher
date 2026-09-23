#!/bin/zsh
# Read-only DXMT 0.80 audit. It does not invoke Wine with a prefix or modify a runtime.
set -euo pipefail

runtime="${1:-}"
[[ -n "$runtime" ]] || { print -u2 -- 'usage: auditDxmt080MacOS14Compatibility.command /absolute/verified/runtime'; exit 64; }
module="$runtime/lib/dxmt/x86_64-unix/winemetal.so"

if [[ ! -f "$module" ]]; then
  print -u2 -- "missing DXMT unix module: $module"
  exit 2
fi

print -- "module=$module"
print -- '== identity =='
file "$module"
shasum -a 256 "$module"
print -- '== deployment target =='
otool -l "$module" | sed -n '/LC_BUILD_VERSION/,+8p'
print -- '== install name and dependent dylibs =='
otool -D "$module"
otool -L "$module"
print -- '== Wine/host-facing undefined symbols =='
nm -u "$module" | rg '(__wine|macdrv|_OBJC_CLASS_\$_(MTL|MTLFX|NS)|_MTL|_sqlite)' || true
print -- '== DXMT package files and hashes =='
find "$runtime/lib/dxmt" -type f -print0 | sort -z | xargs -0 shasum -a 256
