#!/usr/bin/env bash
# Compiles the key-value node and writes jepsen/peace.tar.gz, which the
# Jepsen test installs on each node. BEAM files do not depend on the
# platform, so the files are compiled on this machine.
set -euo pipefail
cd "$(dirname "$0")/.."
rebar3 as jepsen compile >/dev/null
LIB=_build/jepsen/lib/peace
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/ebin" "$STAGE/bench" "$STAGE/node"
cp "$LIB"/ebin/*.beam "$LIB"/ebin/*.app "$STAGE/ebin/"
cp "$LIB"/bench/peace_kv.beam "$STAGE/bench/"
cp "$LIB"/jepsen/node/*.beam "$STAGE/node/"
tar -czf jepsen/peace.tar.gz -C "$STAGE" ebin bench node
