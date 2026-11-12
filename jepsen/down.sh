#!/usr/bin/env bash
# Stops and removes the containers of the Jepsen test.
set -euo pipefail
cd "$(dirname "$0")/docker"
docker-compose down
