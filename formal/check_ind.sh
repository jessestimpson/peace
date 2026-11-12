#!/usr/bin/env bash
# Check the inductive invariant of FlexiblePaxosInd.tla with Apalache.
#   usage: check_ind.sh <ConstInit> [init|step|safe]...
#          check_ind.sh all | refines
# <ConstInit> is an operator of MCFlexiblePaxosInd.tla, for example C3E2I2.
# With no further argument the script checks all three implications:
#   init  Init => IndInv
#   step  IndInv /\ Next => IndInv'
#   safe  IndInv => Safety, given QuorumIntersection of the constants
# `all` runs:
# - the bounds listed below, which take about three minutes
# - the two sets of constants that must fail
# - `refines`, in which TLC checks that FlexiblePaxosInd.tla is the same
#   protocol as FlexiblePaxos.tla (FPaxosIndRefines.tla)
# Apalache is $APALACHE if it is set, then apalache-mc on the path, then the
# copy unpacked by hand under _build/apalache-dl. Apalache is not vendored
# because the release is 190 MB.
#
# The script skips a check if the inputs of the check have not changed since
# the check last gave the expected result. check_all.sh does the same. The
# results are in checked_ind.tsv. The inputs are the modules and this script.
# For `refines` the TLC jar is also an input. Comments are removed before
# hashing, except the Apalache type annotations, which are comments that
# Apalache reads. FORCE=1 runs every check.
set -euo pipefail
cd "$(dirname "$0")"

LEDGER="checked_ind.tsv"
TAB="$(printf '\t')"

inputs_hash() { # tool, files...
  local tool="$1"
  shift
  {
    for f in "$@"; do
      uncommented "$f"
      grep '@type' "$f" || true
    done
    grep -v '^[[:space:]]*#' check_ind.sh
    echo "$tool"
  } | shasum -a 256 | cut -c1-16
}

# A TLA+ or config file without its comments and blank lines. Block comments
# nest. This is the same function as in check_all.sh.
uncommented() { # file
  perl -0pe '
    1 while s/\(\*(?:(?!\(\*|\*\)).)*\*\)//s;
    s/\\\*[^\n]*//g;
    s/[ \t]+$//mg;
    s/\n{2,}/\n/g;
  ' "$1"
}

# Returns success and prints a message if the ledger has this key with this
# hash.
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
  for C in C3E2I2 C3E3I1 C5E2I1 C3E3I3; do ./check_ind.sh "$C"; done
  # Each set of constants must fail, and must fail at the named implication.
  for PAIR in NoGuard3:step Unsafe3:safe; do
    # shellcheck disable=SC2086
    HASH="$(inputs_hash apalache $IND_FILES)"
    if recorded "$PAIR:fails" "$HASH"; then continue; fi
    if FORCE=1 ./check_ind.sh "${PAIR%%:*}" "${PAIR##*:}" >/dev/null 2>&1; then
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
  ./check_ind.sh refines
  echo "inductive invariant: all as expected"
  exit 0
fi
# TLC checks that FlexiblePaxosInd is the same protocol as FlexiblePaxos, and
# that IndInv holds in every reachable state.
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
