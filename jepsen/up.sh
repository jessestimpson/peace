#!/usr/bin/env bash
# Builds and starts the containers of the Jepsen test. See README.md.
#   usage: jepsen/up.sh
# The script needs a running Docker daemon.
set -euo pipefail
cd "$(dirname "$0")/docker"
mkdir -p secret
if [ ! -f secret/id_rsa ]; then
  ssh-keygen -q -t rsa -b 2048 -m PEM -N "" -f secret/id_rsa
fi
docker-compose up -d --build
