#!/usr/bin/env bash
# Runs the Jepsen test repeatedly for a number of hours. See README.md.
#   usage: jepsen/soak.sh HOURS [MINUTES_PER_RUN]
#   example: jepsen/soak.sh 24
# The script cycles through the configurations below. Each run lasts
# MINUTES_PER_RUN minutes (default 10). The script appends one line per run
# to jepsen/soak.log.
#
# The exit status of a run gives the result of the run:
#   0      The history is linearizable.
#   2      The checker did not finish, for example because it ran out of
#          memory. No violation was found. The script counts the run as
#          unchecked, keeps the output in jepsen/soak-unchecked-RUN.log and
#          continues.
#   other  The history has a violation, or the test crashed. The script
#          keeps the output in jepsen/soak-failure-RUN.log and stops.
# The exit status of the script is 0 if no run had a violation or a crash.
#
# A soak of many short runs is used instead of one long run, because the
# memory that the checker needs grows with the length of a history.
set -uo pipefail
cd "$(dirname "$0")"
HOURS="${1:?usage: jepsen/soak.sh HOURS [MINUTES_PER_RUN]}"
SECONDS_PER_RUN=$(( ${2:-10} * 60 ))
LOG=soak.log
END=$(( $(date +%s) + HOURS * 3600 ))

# One configuration per line: the nodes, then the options of the test.
CONFIGS=(
  "n1,n2,n3,n4,n5 --quorum majority --faults partition,kill,pause"
  "n1,n2,n3,n4,n5 --quorum majority --faults partition,kill,pause,members"
  "n1,n2,n3,n4,n5 --quorum majority --faults partition,kill,pause,quorums"
  "n1,n2,n3,n4,n5 --quorum counting:4:2 --faults partition,kill,pause"
  "n1,n2,n3,n4,n5 --quorum counting:2:4 --ops-per-key 50 --faults partition,kill,pause"
  "n1,n2,n3,n4 --quorum grid:2 --faults partition,kill,pause"
  "n1,n2,n3,n4,n5 --quorum weighted:2+1+1+1+1 --faults partition,kill,pause"
  "n1,n2,n3,n4,n5 --quorum majority --read-lease-ms 100 --clock-rate-spread 8 --wall-clock-skew --faults partition,kill,pause"
)

# Keep the machine awake on macOS for as long as this script runs.
if command -v caffeinate >/dev/null; then
  caffeinate -i -w $$ &
fi

run=0
passed=0
unchecked=0
echo "$(date -u +%FT%TZ) soak start: $HOURS hours, $SECONDS_PER_RUN seconds per run" >> "$LOG"
while [ "$(date +%s)" -lt "$END" ]; do
  config="${CONFIGS[$(( run % ${#CONFIGS[@]} ))]}"
  nodes="${config%% *}"
  options="${config#* }"
  run=$(( run + 1 ))
  out="$(mktemp)"
  # shellcheck disable=SC2086
  NODES="$nodes" ./run.sh --time-limit "$SECONDS_PER_RUN" $options > "$out" 2>&1
  status=$?
  ok="$(grep -m1 -o ':ok-count [0-9]*' "$out" | grep -o '[0-9]*' || echo '?')"
  echo "$(date -u +%FT%TZ) run $run status $status ok-operations $ok nodes $nodes options $options" >> "$LOG"
  if [ "$status" -eq 2 ]; then
    cp "$out" "soak-unchecked-$run.log"
    unchecked=$(( unchecked + 1 ))
    rm -f "$out"
    continue
  fi
  if [ "$status" -ne 0 ]; then
    cp "$out" "soak-failure-$run.log"
    echo "$(date -u +%FT%TZ) soak stopped: run $run did not pass. Output: jepsen/soak-failure-$run.log" >> "$LOG"
    rm -f "$out"
    exit 1
  fi
  passed=$(( passed + 1 ))
  rm -f "$out"
done
echo "$(date -u +%FT%TZ) soak end: $passed of $run runs passed, $unchecked unchecked" >> "$LOG"
