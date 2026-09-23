#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
output="${1:-$script_dir/IdentityVRuntimeBootstrap}"
mkdir -p "${output:h}"
cd "$script_dir"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$output" .
codesign --force --sign - "$output" >/dev/null
codesign --verify --strict "$output"
print -- "built $output"
