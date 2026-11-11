#!/usr/bin/env bash
# Hold one run of the code against the model.
#   usage: check_trace.sh <dir>
# <dir> holds TraceData.tla, TraceData.len and events.txt, as written by
# dst/peace_dst_trace.erl. Exits 0 if the run is a behaviour of
# FlexiblePaxos.tla. If it is not, prints the action the model refused and
# exits 1. TLC's output is left in <dir>/tlc.log.
set -euo pipefail
DIR="$(cd "${1:?usage: check_trace.sh <dir>}" && pwd)"
cd "$(dirname "$0")"
if [ -n "${TLA2TOOLS_JAR:-}" ]; then
  JAR="$TLA2TOOLS_JAR"
elif [ -f tla2tools.jar ]; then
  JAR="tla2tools.jar"
else
  JAR="vendor/tla2tools-v1.8.0.jar"
fi
LEN="$(cat "$DIR/TraceData.len")"
META="$(mktemp -d)"
trap 'rm -rf "$META"' EXIT

set +e
# One behaviour, so one worker. -deadlock: the behaviour is meant to end.
java -XX:+UseParallelGC -DTLA-Library="$DIR" -cp "$JAR" tlc2.TLC \
  -workers 1 -deadlock -noGenerateSpecTE -metadir "$META" \
  -config TraceFlexiblePaxos.cfg TraceFlexiblePaxos.tla >"$DIR/tlc.log" 2>&1
STATUS=$?
set -e

DEPTH="$(sed -n 's/^The depth of the complete state graph search is \([0-9]*\)\.$/\1/p' "$DIR/tlc.log")"
if [ "$STATUS" -eq 0 ] && [ "$DEPTH" = "$((LEN + 1))" ]; then
  echo "accepted: $LEN actions"
  exit 0
fi
if [ "$STATUS" -eq 0 ] && [ -n "$DEPTH" ]; then
  echo "REJECTED at action $DEPTH of $LEN:"
  sed -n "${DEPTH}p" "$DIR/events.txt"
  exit 1
fi
echo "ERROR: TLC exited $STATUS; see $DIR/tlc.log"
tail -20 "$DIR/tlc.log"
exit 2
