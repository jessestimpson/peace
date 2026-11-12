#!/usr/bin/env bash
# Runs the Jepsen test in the control container. See README.md.
#   usage: jepsen/run.sh [options of the test]
#   example: jepsen/run.sh --time-limit 120 --faults partition,kill
# The containers must be running (jepsen/up.sh). The results are written to
# jepsen/peace/store. The environment variable NODES selects the nodes. The
# default is n1,n2,n3,n4,n5.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
docker exec peace-jepsen-control lein run test \
  --nodes "${NODES:-n1,n2,n3,n4,n5}" \
  --username root \
  --ssh-private-key /root/.ssh-jepsen/id_rsa \
  --concurrency 10 \
  "$@"
