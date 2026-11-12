#!/bin/sh
# Runs benchmark suites. See bench/README.md.
#
# Usage: bench/run.sh <suite>...
# Suites: smoke, throughput, value_size, propose_to, reads, failover,
#         restart, catch_up, all.
#
# PEACE_BENCH_NODE_FLAGS sets extra emulator flags for the server nodes.
set -e
cd "$(dirname "$0")/.."
rebar3 as bench compile >/dev/null
lib=_build/bench/lib/peace
exec erl -noshell -sname peace_bench_ctl -setcookie peace_bench \
    -kernel prevent_overlapping_partitions false \
    -pa "$PWD/$lib/ebin" -pa "$PWD/$lib/bench" \
    -run peace_bench main "$@"
