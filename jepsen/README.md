# Jepsen test

This directory contains a [Jepsen](https://github.com/jepsen-io/jepsen) test
of peace. The test runs a key-value store on separate Erlang nodes, injects
faults, and checks that the client history is linearizable. The checker is
[Knossos](https://github.com/jepsen-io/knossos), which is independent of
peace.

## Requirements

- Docker, with `docker-compose`.
- Erlang/OTP 28 and rebar3 on the host. The host compiles the key-value
  node.

The control container downloads Jepsen 0.3.9 and its dependencies from
Clojars and Maven Central on the first run.

## Commands

| Command | Action |
|---|---|
| `jepsen/up.sh` | Builds the images and starts five node containers and one control container. |
| `jepsen/run.sh [options]` | Compiles the key-value node and runs the test in the control container. |
| `jepsen/down.sh` | Stops and removes the containers. |
| `make jepsen` | Runs `jepsen/run.sh` with the default options. |

`jepsen/run.sh` exits with status 0 if the history is linearizable. The
results of each run are written to `jepsen/peace/store`.

The environment variable `NODES` selects the nodes. The default is
`n1,n2,n3,n4,n5`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--time-limit SECONDS` | 60 | The duration of the run. |
| `--faults LIST` | `partition,kill,pause` | A comma-separated list of `partition`, `kill`, `pause` and `members`, or `none`. |
| `--quorum SPEC` | `majority` | The quorum system: `majority`, `counting:Q1:Q2`, or `grid:R` for rows of `R` nodes. |
| `--nemesis-interval SECONDS` | 10 | The mean time between two fault operations. |
| `--rate HZ` | 10 | The mean number of operations per second on each key. |
| `--ops-per-key COUNT` | 200 | The number of operations on each key. |
| `--threads-per-key COUNT` | 5 | The number of client threads that share a key. |
| `--stale-reads` | off | Nodes answer reads from local state. The test is expected to fail. |

Example:

```bash
jepsen/run.sh --time-limit 300 --faults partition,kill,pause,members
```

## Test design

Each node runs one peace server with the
[peace_kv](../bench/peace_kv.erl) machine and the default storage backend,
the write-ahead log. [peace_kv_node](node/peace_kv_node.erl) starts the
server. [peace_kv_http](node/peace_kv_http.erl) is an HTTP server for the
clients of the test.

Ten client threads perform reads, writes and compare-and-set operations on
integer keys. Five threads share one key. A read uses
`peace:consistent_query/3`. The clients do not use sessions and do not retry
an operation.

The client maps the HTTP status to a Jepsen result:

| Status | Meaning | Jepsen result |
|---|---|---|
| 200, 204 | The operation was applied. | `ok` |
| 404, 409 | The key is absent, or the compare-and-set found another value. | `fail` |
| 503 | The node did not submit the operation. | `fail` |
| 504, timeout, connection error | The outcome is unknown. | `info` for a write or a compare-and-set, `fail` for a read |

The faults are:

| Fault | Action |
|---|---|
| `partition` | Isolates one node, splits a majority from a minority, or creates a ring of overlapping majorities. Uses iptables. |
| `kill` | Sends SIGKILL to the Erlang emulator on one node, a majority of the nodes, or every node. The node is started again later and recovers from the write-ahead log. |
| `pause` | Sends SIGSTOP to the Erlang emulator on one node or a majority of the nodes, and SIGCONT later. |
| `members` | Asks a random node to change the members to a random set of 3 to 5 nodes, with majority quorums. |

Every fault is healed before the end of the run.

The checker treats each key as a compare-and-set register and searches for
a linearization of the history of the key.

## Results

The runs were performed on 2026-11-12, on one Apple M4 Mac, with Docker
Desktop 20.10.8 (4 CPUs, 1.94 GB of memory for all six containers) and
Erlang/OTP 28.

| Quorum system | Nodes | Faults | Duration | Operations ok | Operations failed | Operations with unknown outcome | Fault operations | Result |
|---|---|---|---|---|---|---|---|---|
| `majority` | 5 | none | 30 s | 443 | 156 | 0 | 0 | linearizable |
| `majority` | 5 | partition, kill, pause | 180 s | 738 | 2,622 | 45 | 36 | linearizable |
| `majority` | 5 | partition, kill, pause, members | 300 s | 1,525 | 4,237 | 65 | 83 | linearizable |
| `{counting, 4, 2}` | 5 | partition, kill, pause | 180 s | 1,151 | 2,316 | 27 | 33 | linearizable |
| `{counting, 2, 4}` | 5 | partition, kill, pause | 180 s | 1,046 | 2,263 | 146 | 45 | linearizable |
| `{grid, Rows}`, two rows of two | 4 | partition, kill, pause | 180 s | 637 | 2,724 | 64 | 42 | linearizable |
| `majority`, with `--stale-reads` | 5 | partition | 120 s | 1,488 | 921 | 21 | 13 | not linearizable, as expected |

Most failed operations are refused connections and `no_leader` answers
while nodes are down or isolated. The other failed operations are
compare-and-set operations that found another value.

In the run with `members`, 3 of 14 membership changes were confirmed, 4 had
an unknown outcome, and 7 were not submitted.

The run with `--stale-reads` confirms that the checker rejects a history
that is not linearizable.

## Limitations

- Clock skew is not tested. The containers share the clock of the Docker
  virtual machine, so the Jepsen clock nemesis cannot change the clock of
  one node. Read leases depend on bounded clock drift. The deterministic
  simulation covers clock drift (see [../README.md](../README.md)).
- The longest run is 300 seconds. A soak test of 24 hours has not been run.
- The `members` fault always changes to majority quorums. Membership change
  with a counting or grid quorum system is not tested.
- A custom quorum module, `{module, Mod, Arg}`, is not tested.
- All containers run on one machine. Network latency is close to zero
  outside a partition, and all nodes share one disk.
- A kill does not discard data that was written and not yet synced, because
  the operating system keeps running. The deterministic simulation covers
  that case with a simulated disk.
- The checker ran out of memory (700 MB heap) on one run of
  `{counting, 2, 4}` with 200 operations per key. With this quorum system
  many writes have an unknown outcome, and the search space grows with each
  one. The run in the table uses `--ops-per-key 50`.
- The test does not corrupt files.

## Source layout

| Path | Content |
|---|---|
| `node/` | The Erlang key-value node. Compiled in the `jepsen` rebar3 profile. |
| `peace/` | The Jepsen test, a Leiningen project. |
| `docker/` | The Dockerfiles and the compose file. `docker/secret` holds the SSH key pair that `up.sh` generates. |
| `build.sh` | Compiles the node and writes `peace.tar.gz`. |
