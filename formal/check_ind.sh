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
#
# A check whose inputs have not changed since it last gave the expected
# result is skipped, as in check_all.sh. The results are in checked_ind.tsv.
# The inputs are the modules and this script (and the TLC jar, for `refines`). Comments
# are not stripped, because Apalache reads its type annotations from them.
# FORCE=1 runs every check.
set -euo pipefail
cd "$(dirname "$0")"

LEDGER="checked_ind.tsv"
TAB="$(printf '\t')"

inputs_hash() { # tool, files...
  local tool="$1"
  shift
  { cat "$@" check_ind.sh; echo "$tool"; } | shasum -a 256 | cut -c1-16
}

# Succeeds, and says so, if the ledger has this key with this hash.
recorded() { # key hash
  local line
  [ -z "${FORCE:-}" ] && [ -f "$LEDGER" ] || return 1
  line="$(grep "^$1$TAB$2$TAB" "$LEDGER" || true)"
  [ -n "$line" ] || return 1
  echo "$1: unchanged since $(echo "$line" | cut -f3), $(echo "$line" | cut -f4)"
}

record() { # key hash result
  local tmp
  tmp="$(mktemp)"
  if [ -f "$LEDGER" ]; then grep -v "^$1$TAB" "$LEDGER" >"$tmp" || true; fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%Y-%m-%d)" "$3" >>"$tmp"
  LC_ALL=C sort "$tmp" >|"$LEDGER"
  rm -f "$tmp"
}

IND_FILES="FlexiblePaxosInd.tla MCFlexiblePaxosInd.tla"
if [ "${1:-}" = all ]; then
  for C in C3E2I2 C3E3I1 C5E2I1 C3E3I3; do "$0" "$C"; done
  # Each must fail, and at the named implication.
  for PAIR in NoGuard3:step Unsafe3:safe; do
    # shellcheck disable=SC2086
    HASH="$(inputs_hash apalache $IND_FILES)"
    if recorded "$PAIR:fails" "$HASH"; then continue; fi
    if FORCE=1 "$0" "${PAIR%%:*}" "${PAIR##*:}" >/dev/null 2>&1; then
      echo "ERROR: ${PAIR%%:*} ${PAIR##*:} held, and was meant to fail"
      exit 1
    fi
    grep -q "state invariant .* violated" "logs/ind-${PAIR%%:*}-${PAIR##*:}.log" || {
      echo "ERROR: ${PAIR%%:*} ${PAIR##*:} failed without a violation; see its log"
      exit 1
    }
    record "$PAIR:fails" "$HASH" "fails, as it should"
    echo "${PAIR%%:*} ${PAIR##*:}: fails, as it should"
  done
  "$0" refines
  echo "inductive invariant: all as expected"
  exit 0
fi
# TLC: FlexiblePaxosInd is FlexiblePaxos, and IndInv holds wherever it goes.
if [ "${1:-}" = refines ]; then
  if [ -n "${TLA2TOOLS_JAR:-}" ]; then JAR="$TLA2TOOLS_JAR"; elif [ -f tla2tools.jar ]; then JAR="tla2tools.jar"; else JAR="vendor/tla2tools-v1.8.0.jar"; fi
  HASH="$(inputs_hash "$JAR" FlexiblePaxosInd.tla FlexiblePaxos.tla FPaxosIndRefines.tla FPaxosIndRefines.cfg)"
  if recorded refines "$HASH"; then exit 0; fi
  META="$(mktemp -d)"
  trap 'rm -rf "$META"' EXIT
  mkdir -p logs
  START=$SECONDS
  if java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock -noGenerateSpecTE -metadir "$META" \
    -config FPaxosIndRefines.cfg FPaxosIndRefines.tla >|logs/ind-refines.log 2>&1; then
    RESULT="holds, $(grep -Eo "[0-9]+ distinct states" logs/ind-refines.log | tail -1), $((SECONDS - START))s"
    record refines "$HASH" "$RESULT"
    echo "refines FlexiblePaxos: $RESULT"
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
  # shellcheck disable=SC2086
  HASH="$(inputs_hash apalache $IND_FILES)"
  if recorded "$CINIT:$PART" "$HASH"; then continue; fi
  LOG="logs/ind-$CINIT-$PART.log"
  START=$SECONDS
  # shellcheck disable=SC2086
  if "$AP" check --out-dir=../_build/apalache-out --cinit="$CINIT" $ARGS MCFlexiblePaxosInd.tla >|"$LOG" 2>&1 \
    && grep -q "EXITCODE: OK" "$LOG"; then
    record "$CINIT:$PART" "$HASH" "holds, $((SECONDS - START))s"
    echo "$CINIT $PART: holds ($((SECONDS - START))s)"
  else
    echo "$CINIT $PART: FAILED ($((SECONDS - START))s); see formal/$LOG"
    grep -E "EXITCODE|violat|Error|error" "$LOG" | tail -5
    exit 1
  fi
done
