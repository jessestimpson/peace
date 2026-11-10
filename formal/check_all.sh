#!/usr/bin/env bash
# Run a set of model configs.
#   usage: check_all.sh [quick|long|all]
# quick: a few minutes. long: the configs with tens of millions of states;
# see README.md for how long each took.
set -euo pipefail
cd "$(dirname "$0")"

QUICK_PASS="FPaxosMajority FPaxosSingleton FPaxosAllAboard FPaxosEvenNodes"
# Mutations: each must produce a counterexample.
QUICK_FAIL="FPaxosUnsafeQuorums FPaxosNoFence FPaxosNoConflictStepDown"
# Reachability: each must reach the state its invariant denies.
QUICK_REACH="FPaxosReachableChosen FPaxosReachableAllLearned FPaxosReachableRecovery FPaxosReachableConflict"
LONG_PASS="FPaxosThreeBallots FPaxosGrid FPaxosSingletonTwoSlots FPaxosMajorityTwoSlots"

run() { # config expectation
  echo "=== $1 (expect $2)"
  local out
  out="$(mktemp)"
  if ./check.sh "$1" "$2" >"$out" 2>&1; then
    grep -E "Invariant .* is violated|distinct states found|No error has been found|^OK:|Finished in" "$out" || true
    rm -f "$out"
  else
    tail -40 "$out"
    rm -f "$out"
    echo "FAILED: $1 did not $2"
    exit 1
  fi
}

SET="${1:-quick}"
if [ "$SET" = quick ] || [ "$SET" = all ]; then
  for c in $QUICK_PASS; do run "$c" pass; done
  for c in $QUICK_FAIL $QUICK_REACH; do run "$c" fail; done
fi
if [ "$SET" = long ] || [ "$SET" = all ]; then
  for c in $LONG_PASS; do run "$c" pass; done
fi
echo "all $SET configs behaved as expected"
