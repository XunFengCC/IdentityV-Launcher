#!/bin/zsh
set -eu

print -r -- "${1:-} prefix=${WINEPREFIX:-missing}" >> "$MOCK_WINESERVER_LOG"
case "${1:-}" in
  -k) /bin/rm -f "$MOCK_WINESERVER_MARKER" ;;
  -w) while [[ -e "$MOCK_WINESERVER_MARKER" ]]; do /bin/sleep 0.02; done ;;
  *) exit 64 ;;
esac
