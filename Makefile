.PHONY: all compile test dst trace tlc tlc-long tlc-soak ind check

all: compile

compile:
	rebar3 compile

# Unit and integration tests, on real processes and the real clock.
test:
	rebar3 eunit

# Deterministic simulation with eta. See dst/peace_dst.erl.
#
# One scheduler thread: a simulated run executes one process at a time, so
# more threads only fight over it. Measured on ten cores, one thread is a
# little faster on an idle machine and uses a sixth of the CPU; on a busy
# machine (TLC running, say) the default is over twenty times slower than it
# is idle, and one thread about three times.
dst:
	ERL_FLAGS="+S 1" rebar3 as dst eunit

# Trace validation: simulated runs, each checked by TLC to be a behaviour of
# formal/FlexiblePaxos.tla. See dst/peace_dst_trace.erl. Needs eta and Java.
trace:
	ERL_FLAGS="+S 1" rebar3 as dst eunit --module=peace_dst_trace_tests

# Model checking with TLC. See formal/README.md. A config whose model has not
# changed since it was last checked is skipped; FORCE=1 runs it anyway.
tlc:
	formal/check_all.sh quick

tlc-long:
	formal/check_all.sh long

tlc-soak:
	formal/check_all.sh soak

# The inductive invariant of formal/FlexiblePaxosInd.tla. Needs Apalache.
ind:
	formal/check_ind.sh all

check: test dst trace tlc
