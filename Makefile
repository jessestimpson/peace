.PHONY: all compile test dst tlc tlc-long check

all: compile

compile:
	rebar3 compile

# Unit and integration tests, on real processes and the real clock.
test:
	rebar3 eunit

# Deterministic simulation with eta. See dst/peace_dst.erl.
dst:
	rebar3 as dst eunit

# Model checking with TLC. See formal/README.md.
tlc:
	formal/check_all.sh quick

tlc-long:
	formal/check_all.sh long

check: test dst tlc
