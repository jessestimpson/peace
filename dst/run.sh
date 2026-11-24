#!/bin/sh
# Runs the simulation suite, dst/peace_dst_tests.erl. Each test runs in an
# Erlang node of its own, and several nodes run at the same time.
#
# Usage: dst/run.sh [-j JOBS] [TEST...]
#
#   -j JOBS  The number of nodes that run at the same time. The default is
#            the number of processors minus 2, and at least 1.
#   TEST     The name of a test of peace_dst_tests, for example
#            churn_test_. The default is every test.
#
# Each node has one scheduler thread and a disk directory of its own. The
# output of each test is in _build/dst-logs/TEST.log. The exit status is 0
# if every test passed.
#
# The tests that took longest in the previous run start first. The times of
# the previous run are in _build/dst-logs/times.
set -e
cd "$(dirname "$0")/.."
build=_build/dst+test
logs=_build/dst-logs
paths="-pa $PWD/$build/lib/peace/ebin -pa $PWD/$build/lib/peace/dst"
# eta is a checkout in `_checkouts/eta', or a dependency that rebar3 has
# fetched.
if [ -d "$build/checkouts/eta" ]; then
    paths="$paths -pa $PWD/$build/checkouts/eta/ebin"
else
    paths="$paths -pa $PWD/$build/lib/eta/ebin"
fi

if [ "$1" = "--one" ]; then
    name=$2
    disk=$PWD/$logs/disk/$name
    mkdir -p "$disk"
    start=$(date +%s)
    status=ok
    # shellcheck disable=SC2086
    PEACE_DST_DISK_DIR=$disk erl +S 1 -noshell $paths -eval "
        case eunit:test({generator, peace_dst_tests, $name}, [verbose]) of
            ok -> halt(0);
            _ -> halt(1)
        end." >"$logs/$name.log" 2>&1 || status=FAILED
    seconds=$(($(date +%s) - start))
    echo "$seconds $name" >>"$logs/times.new"
    printf '%-7s %5d s  %s\n' "$status" "$seconds" "$name"
    [ "$status" = ok ]
    exit
fi

jobs=$(($( (getconf _NPROCESSORS_ONLN || echo 3) 2>/dev/null) - 2))
[ "$jobs" -ge 1 ] || jobs=1
if [ "$1" = "-j" ]; then
    jobs=$2
    shift 2
fi

rebar3 as dst,test compile >/dev/null
mkdir -p "$logs"
: >"$logs/times.new"

if [ $# -gt 0 ]; then
    tests=$(printf '%s\n' "$@")
else
    # shellcheck disable=SC2086
    tests=$(erl -noshell $paths -eval '
        Names = [atom_to_list(F) || {F, 0} <- peace_dst_tests:module_info(exports)],
        [io:format("~s~n", [N]) || N <- Names, lists:suffix("_test_", N)],
        halt().')
fi

# The tests with a time from the previous run come first, longest first. A
# test without a time comes before them.
touch "$logs/times"
ordered=$(printf '%s\n' "$tests" | while read -r name; do
    seconds=$(awk -v n="$name" '$2 == n { print $1 }' "$logs/times")
    echo "${seconds:-999999} $name"
done | sort -rn | awk '{ print $2 }')

count=$(printf '%s\n' "$ordered" | wc -l | tr -d ' ')
echo "$count tests, $jobs at the same time, output in $logs"
start=$(date +%s)
result=0
printf '%s\n' "$ordered" | xargs -P "$jobs" -n 1 "$0" --one || result=1
if [ $# -eq 0 ]; then
    mv "$logs/times.new" "$logs/times"
fi
seconds=$(($(date +%s) - start))
if [ "$result" -eq 0 ]; then
    echo "All $count tests passed in $seconds s."
else
    echo "At least one test failed. Time: $seconds s."
fi
exit "$result"
