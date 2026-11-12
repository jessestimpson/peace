#!/usr/bin/env bash
# Checks one client history of a simulated run with Porcupine.
#   usage: check_history.sh <history.json>
# The history is written by dst/peace_dst_history.erl. The script prints
# "ok", "ILLEGAL" or "unknown", and the number of operations checked. If
# the history is not linearizable, the script writes a visualization next
# to the history, with the extension .html.
#
# The script builds the checker in _build/porcupine on first use. The
# script needs Go.
set -euo pipefail
FILE="$(cd "$(dirname "${1:?usage: check_history.sh <history.json>}")" && pwd)/$(basename "$1")"
cd "$(dirname "$0")/.."
BIN="$PWD/_build/porcupine/porcupine"
if [ ! -x "$BIN" ] || [ dst/porcupine/main.go -nt "$BIN" ]; then
  mkdir -p "$(dirname "$BIN")"
  (cd dst/porcupine && go build -o "$BIN" .)
fi
"$BIN" "$FILE" || {
  STATUS=$?
  [ "$STATUS" -eq 1 ] && "$BIN" -html "${FILE%.json}.html" "$FILE" >/dev/null || true
  exit "$STATUS"
}
