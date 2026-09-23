#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
/usr/bin/clang -mmacosx-version-min=14.0 -O2 -Wall -Wextra -Werror -o "$ROOT/idv-dense-metrics" "$ROOT/idv_dense_metrics.c" -lproc
/usr/bin/codesign --force --sign - "$ROOT/idv-dense-metrics" >/dev/null
"$ROOT/../runtimeManifest/auditMachODeploymentTargets.command" "$ROOT/idv-dense-metrics"
echo "Built $ROOT/idv-dense-metrics"
