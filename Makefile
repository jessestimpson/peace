.PHONY: all compile test dst tlc tlc-long tlc-soak check

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

# Model checking with TLC. See formal/README.md. A config whose model has not
# changed since it was last checked is skipped; FORCE=1 runs it anyway.
tlc:
	formal/check_all.sh quick

tlc-long:
	formal/check_all.sh long

tlc-soak:
	formal/check_all.sh soak

check: test dst tlc
