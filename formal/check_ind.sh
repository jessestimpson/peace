#!/usr/bin/env bash
# Check the inductive invariant of FlexiblePaxosInd.tla with Apalache.
#   usage: check_ind.sh <ConstInit> [init|step|safe]...
#          check_ind.sh all | refines
# <ConstInit> is an operator of MCFlexiblePaxosInd.tla, e.g. C3E2I2. With no
# further argument all three implications are checked:
#   init  Init => IndInv
#   step  IndInv /\ Next => IndInv'
#   safe  IndInv => Safety, given QuorumIntersection of the constants
# `all` runs the bounds below, about five minutes, the two instances that
# are meant to fail, and `refines`: TLC checking that FlexiblePaxosInd.tla is
# FlexiblePaxos.tla (FPaxosIndRefines.tla).
# Apalache: $APALACHE, else apalache-mc on the path, else the copy unpacked
# under _build/apalache-dl by hand (it is not vendored: 190 MB).
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = all ]; then
  for C in C3E2I2 C3E3I1 C5E2I1 C3E3I3; do "$0" "$C"; done
  # Each must fail, and at the named implication.
  for PAIR in NoGuard3:step Unsafe3:safe; do
    if "$0" "${PAIR%%:*}" "${PAIR##*:}" >/dev/null 2>&1; then
      echo "ERROR: ${PAIR%%:*} ${PAIR##*:} held, and was meant to fail"
      exit 1
    fi
    grep -q "state invariant .* violated" "logs/ind-${PAIR%%:*}-${PAIR##*:}.log" || {
      echo "ERROR: ${PAIR%%:*} ${PAIR##*:} failed without a violation; see its log"
      exit 1
    }
    echo "${PAIR%%:*} ${PAIR##*:}: fails, as it should"
  done
  "$0" refines
  echo "inductive invariant: all as expected"
  exit 0
fi
# TLC: FlexiblePaxosInd is FlexiblePaxos, and IndInv holds wherever it goes.
if [ "${1:-}" = refines ]; then
  if [ -n "${TLA2TOOLS_JAR:-}" ]; then JAR="$TLA2TOOLS_JAR"; elif [ -f tla2tools.jar ]; then JAR="tla2tools.jar"; else JAR="vendor/tla2tools-v1.8.0.jar"; fi
  META="$(mktemp -d)"
  trap 'rm -rf "$META"' EXIT
  mkdir -p logs
  START=$SECONDS
  if java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock -noGenerateSpecTE -metadir "$META" \
    -config FPaxosIndRefines.cfg FPaxosIndRefines.tla >|logs/ind-refines.log 2>&1; then
    echo "refines FlexiblePaxos: holds, $(grep -Eo "[0-9]+ distinct states" logs/ind-refines.log | tail -1) ($((SECONDS - START))s)"
    exit 0
  fi
  echo "refines FlexiblePaxos: FAILED; see formal/logs/ind-refines.log"
  exit 1
fi
CINIT="${1:?usage: check_ind.sh <ConstInit> [init|step|safe]... | all}"
shift
[ $# -gt 0 ] || set -- init step safe
if [ -n "${APALACHE:-}" ]; then
  AP="$APALACHE"
elif command -v apalache-mc >/dev/null 2>&1; then
  AP="apalache-mc"
else
  AP="$(ls ../_build/apalache-dl/apalache-*/bin/apalache-mc 2>/dev/null | tail -1)"
fi
[ -n "$AP" ] || { echo "ERROR: no apalache-mc; set APALACHE"; exit 2; }
mkdir -p logs
for PART in "$@"; do
  case "$PART" in
    init) ARGS="--init=Init --inv=IndInv --length=0" ;;
    step) ARGS="--init=IndInv --inv=IndInv --length=1" ;;
    safe) ARGS="--init=IndInv --inv=Safety --length=0" ;;
    *) echo "unknown part: $PART"; exit 2 ;;
  esac
  LOG="logs/ind-$CINIT-$PART.log"
  START=$SECONDS
  # shellcheck disable=SC2086
  if "$AP" check --out-dir=../_build/apalache-out --cinit="$CINIT" $ARGS MCFlexiblePaxosInd.tla >|"$LOG" 2>&1 \
    && grep -q "EXITCODE: OK" "$LOG"; then
    echo "$CINIT $PART: holds ($((SECONDS - START))s)"
  else
    echo "$CINIT $PART: FAILED ($((SECONDS - START))s); see formal/$LOG"
    grep -E "EXITCODE|violat|Error|error" "$LOG" | tail -5
    exit 1
  fi
done
