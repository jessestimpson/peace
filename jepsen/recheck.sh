#!/usr/bin/env bash
# Checks the stored histories of Jepsen runs again, with the Porcupine
# checker. See "Soak test" in README.md.
#   usage: jepsen/recheck.sh [FIRST_RUN]
#   example: jepsen/recheck.sh 20261120T0233
# The script checks the history of every key of every run in
# jepsen/peace/store whose directory name is FIRST_RUN or later. Without
# FIRST_RUN it checks every run. The name of a run directory is the start
# time of the run. The script prints the number of runs, and the number of
# keys with each verdict. It prints the path of each history whose verdict
# is not "ok". The exit status is 0 if every verdict is "ok".
#
# The script needs Go 1.19 or later.
set -euo pipefail
cd "$(dirname "$0")"
FIRST="${1:-}"
(cd recheck && go build -o recheck .)
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
runs=0
while read -r dir; do
  runs=$(( runs + 1 ))
  ./recheck/recheck "$dir"/independent/*/history.edn >> "$out" || true
done < <(find peace/store -mindepth 2 -maxdepth 2 -type d -name '2*T*' \
           | awk -F/ -v first="$FIRST" '$NF >= first' | sort)
echo "runs: $runs"
cut -f1 "$out" | sort | uniq -c | awk '{ print "keys with the verdict " $2 ": " $1 }'
if grep -v '^ok' "$out"; then
  exit 1
fi
