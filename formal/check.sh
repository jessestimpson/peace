#!/usr/bin/env bash
# Run TLC on one model config.
#   usage: check.sh <ConfigBasenameWithout.cfg> [pass|fail]
# With `fail`, the script requires TLC to find an invariant violation. Use
# `fail` for mutation configs and reachability configs.
# The TLC jar is $TLA2TOOLS_JAR if it is set, then formal/tla2tools.jar, then
# the jar in formal/vendor.
set -euo pipefail
cd "$(dirname "$0")"

CFG="${1:?usage: check.sh <config-basename> [pass|fail]}"
EXPECT="${2:-pass}"
if [ -n "${TLA2TOOLS_JAR:-}" ]; then
  JAR="$TLA2TOOLS_JAR"
elif [ -f tla2tools.jar ]; then
  JAR="tla2tools.jar"
else
  JAR="vendor/tla2tools-v1.8.0.jar"
fi
# The name of the config determines the module that TLC checks.
case "$CFG" in
  Reconfig*) MODULE="MCReconfig.tla" ;;
  *) MODULE="MCFlexiblePaxos.tla" ;;
esac
OUT="$(mktemp)"
# Each run has its own metadir, so that one run cannot delete the state pools
# of another run that is in progress at the same time.
META="$(mktemp -d)"
trap 'rm -rf "$OUT" "$META"' EXIT

set +e
# -noGenerateSpecTE: TLC writes no trace-explorer files for the configs that
# must fail.
# -deadlock disables deadlock checking. A bounded model has no enabled action
# after every epoch and index is used. That state is not an error.
java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
  -workers auto -deadlock -noGenerateSpecTE -metadir "$META" \
  -config "${CFG}.cfg" "$MODULE" 2>&1 | tee "$OUT"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$EXPECT" = "pass" ]; then
  exit "$STATUS"
fi

# Expected failure: require an invariant violation. A parse error or a JVM
# crash does not count as the expected failure.
if [ "$STATUS" -ne 0 ] && grep -Eq "Invariant .* is violated" "$OUT"; then
  echo "OK: expected invariant violation was found"
  exit 0
fi
echo "ERROR: expected an invariant violation, but TLC exited $STATUS without one"
exit 1
