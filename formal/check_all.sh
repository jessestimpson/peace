#!/usr/bin/env bash
# Run a set of model configs.
#   usage: check_all.sh [quick|long|soak|all]
#          check_all.sh hash <Config>
# - quick takes a few minutes.
# - long runs the configs with millions of states. It takes about 2 hours.
# - soak takes hours.
# README.md gives the time that each config took.
#
# The script skips a config if the inputs of the config have not changed
# since the config last gave the expected result. The result of TLC depends
# only on the model and the config. The inputs are:
# - the config and the two modules it uses, without comments
# - check.sh, without comments
# - the name of the jar
# checked.tsv records a hash of the inputs beside each result. FORCE=1 runs
# every config in the set. The output of each run is kept in
# logs/<Config>.log.
set -euo pipefail
cd "$(dirname "$0")"

QUICK_PASS="FPaxosMajority FPaxosSingleton FPaxosAllAboard FPaxosEvenNodes FPaxosSnapshots ReconfigCoLocated"
# Mutations: each config must produce a counterexample.
QUICK_FAIL="FPaxosUnsafeQuorums FPaxosNoFence FPaxosNoConflictStepDown FPaxosNoSnapshotGuard ReconfigNoJoint ReconfigCoLocatedNoJoint ReconfigCoLocatedNoClosure"
# Reachability: each config must reach the state that the invariant of the
# config says is never reached.
QUICK_REACH="FPaxosReachableDecided FPaxosReachableAllLearned FPaxosReachableRecovery FPaxosReachableConflict FPaxosReachableSnapshot ReconfigCoLocatedReachableFinal ReconfigCoLocatedReachableRaised ReconfigReachableAfterFinal"
LONG_PASS="FPaxosThreeEpochs FPaxosGrid FPaxosFiveAcceptors FPaxosSingletonTwoIndexes FPaxosMajorityTwoIndexes Reconfig"
# Membership change with separate roles: one mutation, which takes about 6
# minutes, and two reachability checks, which take seconds.
LONG_FAIL="ReconfigNoClosure ReconfigReachableFinal ReconfigReachableRaised"
SOAK_PASS="ReconfigThreeIndexes"

LEDGER="checked.tsv"
TAB="$(printf '\t')"

jar_name() {
  if [ -n "${TLA2TOOLS_JAR:-}" ]; then
    basename "$TLA2TOOLS_JAR"
  elif [ -f tla2tools.jar ]; then
    echo tla2tools.jar
  else
    echo tla2tools-v1.8.0.jar
  fi
}

inputs_hash() { # config
  local modules
  case "$1" in
    Reconfig*) modules="MCReconfig.tla Reconfig.tla" ;;
    *) modules="MCFlexiblePaxos.tla FlexiblePaxos.tla" ;;
  esac
  # shellcheck disable=SC2086
  { uncommented "$1.cfg" $modules; grep -v '^[[:space:]]*#' check.sh; jar_name; } | shasum -a 256 | cut -c1-16
}

# Print TLA+ and config files without comments and blank lines, so that a
# change to a comment does not cause a run. Block comments nest.
uncommented() { # files
  perl -0pe '
    1 while s/\(\*(?:(?!\(\*|\*\)).)*\*\)//s;
    s/\\\*[^\n]*//g;
    s/[ \t]+$//mg;
    s/\n{2,}/\n/g;
  ' "$@"
}

run() { # config expectation
  local hash line out summary
  hash="$(inputs_hash "$1")"
  if [ -z "${FORCE:-}" ] && [ -f "$LEDGER" ]; then
    line="$(grep "^$1$TAB$2$TAB$hash$TAB" "$LEDGER" || true)"
    if [ -n "$line" ]; then
      echo "=== $1 (expect $2): unchanged since $(echo "$line" | cut -f4), $(echo "$line" | cut -f5)"
      return
    fi
  fi
  echo "=== $1 (expect $2)"
  # The full TLC output is kept in a log file. The result of a run that takes
  # hours can then be read from the log, and nobody has to watch the run.
  mkdir -p logs
  out="logs/$1.log"
  if ./check.sh "$1" "$2" >|"$out" 2>&1; then
    grep -E "Invariant .* is violated|distinct states found|No error has been found|^OK:|Finished in" "$out" || true
    summary="$(grep -Eo "[0-9,]+ distinct states found" "$out" | tail -1 | sed 's/ found//'), $(grep -Eo "Finished in [0-9a-z ]+" "$out" | tail -1 | sed -e 's/Finished in //' -e 's/ at $//')"
    record "$1" "$2" "$hash" "$summary"
  else
    tail -40 "$out"
    echo "FAILED: $1 did not $2"
    exit 1
  fi
}

record() { # config expectation hash summary
  local tmp
  tmp="$(mktemp)"
  if [ -f "$LEDGER" ]; then
    grep -v "^$1$TAB" "$LEDGER" >"$tmp" || true
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date +%Y-%m-%d)" "$4" >>"$tmp"
  LC_ALL=C sort "$tmp" >"$LEDGER"
  rm -f "$tmp"
}

SET="${1:-quick}"
case "$SET" in
  hash)
    inputs_hash "${2:?usage: check_all.sh hash <Config>}"
    exit 0 ;;
  quick|long|soak|all) ;;
  *)
    echo "usage: check_all.sh [quick|long|soak|all] | hash <Config>" >&2
    exit 2 ;;
esac
if [ "$SET" = quick ] || [ "$SET" = all ]; then
  for c in $QUICK_PASS; do run "$c" pass; done
  for c in $QUICK_FAIL $QUICK_REACH; do run "$c" fail; done
fi
if [ "$SET" = long ] || [ "$SET" = all ]; then
  for c in $LONG_PASS; do run "$c" pass; done
  for c in $LONG_FAIL; do run "$c" fail; done
fi
if [ "$SET" = soak ] || [ "$SET" = all ]; then
  for c in $SOAK_PASS; do run "$c" pass; done
fi
echo "all $SET configs behaved as expected"
