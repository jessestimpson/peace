#!/usr/bin/env bash
# Run TLC on one model config.
#   usage: check.sh <ConfigBasenameWithout.cfg> [pass|fail]
# `fail` asserts TLC finds an invariant violation (mutation and reachability
# configs).
# Jar: $TLA2TOOLS_JAR, else formal/tla2tools.jar, else the vendored one.
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
# The module a config instantiates goes by the config's name.
case "$CFG" in
  Reconfig*) MODULE="MCReconfig.tla" ;;
  *) MODULE="MCFlexiblePaxos.tla" ;;
esac
OUT="$(mktemp)"
# A private metadir per run, so concurrent invocations cannot delete each
# other's state pools.
META="$(mktemp -d)"
trap 'rm -rf "$OUT" "$META"' EXIT

set +e
# -noGenerateSpecTE: no trace-explorer files left behind by the configs that
# are meant to fail.
# -deadlock disables deadlock checking: a bounded model legitimately runs out
# of enabled actions once every epoch and index is used up.
java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
  -workers auto -deadlock -noGenerateSpecTE -metadir "$META" \
  -config "${CFG}.cfg" "$MODULE" 2>&1 | tee "$OUT"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$EXPECT" = "pass" ]; then
  exit "$STATUS"
fi

# Expected failure: demand a genuine invariant violation, so a parse error or
# a JVM crash cannot pass for the counterexample.
if [ "$STATUS" -ne 0 ] && grep -Eq "Invariant .* is violated" "$OUT"; then
  echo "OK: expected invariant violation was found"
  exit 0
fi
echo "ERROR: expected an invariant violation, but TLC exited $STATUS without one"
exit 1
