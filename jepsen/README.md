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
| `jepsen/soak.sh HOURS [MINUTES_PER_RUN]` | Runs the test repeatedly for `HOURS` hours. See "Soak test". |
| `make jepsen` | Runs `jepsen/run.sh` with the default options. |

`jepsen/run.sh` exits with status 0 if the history is linearizable. The
results of each run are written to `jepsen/peace/store`.

The environment variable `NODES` selects the nodes. The default is
`n1,n2,n3,n4,n5`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--time-limit SECONDS` | 60 | The duration of the run. |
| `--faults LIST` | `partition,kill,pause` | A comma-separated list of `partition`, `kill`, `pause`, `members` and `quorums`, or `none`. |
| `--quorum SPEC` | `majority` | The quorum system: `majority`, `counting:Q1:Q2`, `grid:R` for rows of `R` nodes, or `weighted:W+W+...` for the weights of the nodes. |
| `--read-lease-ms MS` | off | The `read_lease_ms` option of the cluster. |
| `--snapshot-interval COUNT` | 4096 | The `snapshot_interval` option of the servers. |
| `--chunk-bytes BYTES` | 262,144 for a transfer, 1,048,576 in the write-ahead log | The size of a chunk of a snapshot. With a small interval and a small chunk size, servers send and store snapshots in several chunks during a run. |
| `--clock-rate-spread PERCENT` | 0 | The width of the range of the clock rates of the nodes. With 8, each start of a node picks a rate between 0.96 and 1.04. |
| `--wall-clock-skew` | off | Each start of a node picks a wall clock offset between -1 hour and +1 hour and a wall clock rate between 0.5 and 2. |
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
| `quorums` | The same as `members`, and also picks a random quorum system: majority, counting with sizes from 2 to N-1, weighted with weights 1 and 2, or a grid of two rows of two when the set has 4 nodes. |

Every fault is healed before the end of the run.

The weighted quorum system is the custom quorum module
[peace_kv_quorum](node/peace_kv_quorum.erl). It tests the
`{module, Mod, Arg}` quorum system.

### Clocks

peace reads only the monotonic clock of the Erlang emulator. The test
changes clocks in two ways:

- `--wall-clock-skew` starts each node under
  [libfaketime](https://github.com/wolfcw/libfaketime). libfaketime changes
  the wall clock of the emulator. It does not change the monotonic clock of
  the emulator (measured on 2026-11-12 with Erlang/OTP 28).
- `--clock-rate-spread` sets the `test_clock_rate` option of each server,
  which multiplies the clock readings that the server uses. The option
  exists only in a build with the `TEST` macro. The `jepsen` rebar3 profile
  sets the macro. The option does not change the timers of the emulator.

Read leases assume that the clock rates of the servers differ by less than
one tenth. See "Read leases" in [peace_core](../src/peace_core.erl).

### Verdict

A run passes if the history of every key is linearizable and no client
threw an unhandled exception. The statistics of the run do not affect the
verdict.

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
| weighted, weights 2, 1, 1, 1, 1 | 5 | partition, kill, pause | 180 s | 1,115 | 2,380 | 27 | 39 | linearizable |
| `majority` | 5 | partition, pause, quorums; interval 15 s | 300 s | 1,458 | 4,175 | 83 | 66 | linearizable |
| `majority` | 5 | partition, kill, pause, quorums; interval 20 s | 300 s | 1,115 | 4,574 | 109 | 46 | linearizable |
| `majority` | 4 | partition, pause, quorums; interval 15 s | 180 s | 1,535 | 1,736 | 81 | 30 | linearizable |
| `majority`, read leases of 100 ms, clock rate spread 8%, wall clock skew | 5 | partition, kill, pause | 300 s | 2,210 | 3,362 | 84 | 63 | linearizable |
| `majority`, read leases of 100 ms, clock rate spread 100% | 5 | partition | 180 s | 2,239 | 1,274 | 14 | 22 | linearizable |
| `majority`, snapshot every 20 indexes, chunks of 64 bytes (run on 2026-11-13) | 5 | partition, kill, pause, members | 300 s | 1,474 | 4,146 | 82 | 89 | linearizable |

Most failed operations are refused connections and `no_leader` answers
while nodes are down or isolated. The other failed operations are
compare-and-set operations that found another value.

In the run with `members`, 3 of 14 membership changes were confirmed, 4 had
an unknown outcome, and 7 were not submitted.

The run with `--stale-reads` confirms that the checker rejects a history
that is not linearizable.

In the three runs with `quorums`, 8 changes were confirmed: 3 to majority,
2 to counting, 2 to a grid and 1 to weighted. 7 more had an unknown
outcome. An earlier run with `quorums` and the default fault interval of
10 seconds was linearizable, and none of its 16 changes was confirmed.

The run with a snapshot every 20 indexes and chunks of 64 bytes makes the
servers store each snapshot in several chunks, and send a snapshot in
several chunks to a server that is behind. The number of snapshots that
were sent in that run was not counted.

The run with a clock rate spread of 100% is outside the assumption of read
leases. The run found no violation. It therefore does not show that the
test can detect a lease that is held for too long.

## Soak test

`jepsen/soak.sh HOURS` runs the test repeatedly. It cycles through eight
configurations: the quorum systems and the fault sets of the table above.
Each run lasts 10 minutes. The script appends one line per run to
`jepsen/soak.log` and stops at the first run that does not pass. On macOS
the script keeps the machine awake with `caffeinate`.

The soak test uses many short runs instead of one long run, because the
memory that the checker needs grows with the length of a history.

A soak test of 24 hours has not been run.

## Limitations

- The monotonic clock of the emulator is not changed. The containers share
  the clock of the Docker virtual machine, and libfaketime does not change
  the monotonic clock of the emulator. The clock rate of a server is
  changed inside peace, with `test_clock_rate`. The timers of the emulator
  keep the real rate.
- A clock does not jump or change rate while a node runs. The clock
  settings change only when a node starts.
- The test has no run that shows a violation when clock rates exceed the
  assumption of read leases. The deterministic simulation has such a run
  (see [../README.md](../README.md)).
- The longest run is 300 seconds. A soak test of 24 hours has not been run.
- Few membership and quorum changes are confirmed in a run, because many
  requests reach a node that is down or has no leader.
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
| `soak.sh` | The soak test. |
