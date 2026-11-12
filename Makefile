.PHONY: all compile test dst trace tlc tlc-long tlc-soak ind check

all: compile

compile:
	rebar3 compile

# Unit and integration tests. They run on real processes and the real clock.
test:
	rebar3 eunit

# Deterministic simulation with eta. See dst/peace_dst.erl.
#
# The run uses one scheduler thread. A simulated run executes one process at
# a time, so additional threads only contend for that one process.
# Measurements on a ten-core machine:
#   - On an idle machine, one thread is a little faster than the default
#     number of threads and uses a sixth of the CPU.
#   - On a busy machine (for example, while TLC is running), the default is
#     over twenty times slower than the default on an idle machine.
#   - On a busy machine, one thread is about three times slower than one
#     thread on an idle machine.
dst:
	ERL_FLAGS="+S 1" rebar3 as dst eunit

# Trace validation. This target performs simulated runs. TLC checks that each
# run is a behaviour of formal/FlexiblePaxos.tla. See dst/peace_dst_trace.erl.
# This target needs eta and Java.
trace:
	ERL_FLAGS="+S 1" rebar3 as dst eunit --module=peace_dst_trace_tests

# Model checking with TLC. See formal/README.md. A config is skipped if its
# model has not changed since the config was last checked. FORCE=1 runs the
# config anyway.
tlc:
	formal/check_all.sh quick

tlc-long:
	formal/check_all.sh long

tlc-soak:
	formal/check_all.sh soak

# Checks the inductive invariant of formal/FlexiblePaxosInd.tla. This target
# needs Apalache.
ind:
	formal/check_ind.sh all

check: test dst trace tlc
