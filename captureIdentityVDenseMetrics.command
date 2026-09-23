#!/bin/zsh
# Observational sampler.  It never attaches a debugger/profiler or asks for privileges.
set -euo pipefail
umask 077
ROOT="${0:A:h}"
BIN="$ROOT/denseMetrics/idv-dense-metrics"
OUTROOT="$ROOT/perfCaptures/dense"
HZ="${IDV_DENSE_HZ:-20}"
SECONDS="${IDV_DENSE_SECONDS:-7200}"
if [[ ! -x "$BIN" ]]; then "$ROOT/denseMetrics/build.command"; fi
PID="$(pgrep -f 'dwrg.exe' | head -n 1 || true)"
if [[ -z "$PID" ]]; then print -u2 'No running dwrg.exe process found; nothing started.'; exit 1; fi
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$OUTROOT/$STAMP-pid-$PID"
mkdir -p "$OUTDIR"
print -r -- "$PID" > "$OUTDIR/target.pid"
ARGS=(--pid "$PID" --output "$OUTDIR/telemetry.jsonl" --hz "$HZ" --seconds "$SECONDS")
# Dense cross-process libproc calls are intentionally omitted: on macOS they
# can block for 100+ ms and destroy the 20 Hz timeline. Join those fields from
# the existing 1 Hz live-window-fps telemetry by wall_time instead.
/usr/bin/nohup "$BIN" "${ARGS[@]}" </dev/null >"$OUTDIR/driver.log" 2>&1 &
SAMPLER_PID=$!
print -r -- "$SAMPLER_PID" > "$OUTDIR/sampler.pid"
print -r -- "Stop with: kill $SAMPLER_PID" > "$OUTDIR/README-stop.txt"
print -r -- "pid=$SAMPLER_PID target=$PID hz=$HZ max_seconds=$SECONDS started=$(date -u +%FT%TZ)" >> "$OUTDIR/driver.log"
disown "$SAMPLER_PID" >/dev/null 2>&1 || true
print "Dense capture started: $OUTDIR (sampler $SAMPLER_PID; max ${SECONDS}s; SIGTERM stops it)."
