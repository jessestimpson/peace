# Benchmarks

This directory contains a key-value state machine, a benchmark harness, and
the results of the benchmark runs of 2026-11-12. The benchmark is milestone 1
of [ROADMAP.md](../ROADMAP.md). It was repeated for milestone 2, with group
commit and the write-ahead log backend. The results below are from the
second run.

## Source layout

| File | Contents |
|---|---|
| [peace_kv.erl](peace_kv.erl) | A key-value state machine and a client for it: put, get, delete, compare-and-swap |
| [peace_kv_tests.erl](peace_kv_tests.erl) | Tests for `peace_kv` |
| [peace_bench.erl](peace_bench.erl) | The benchmark harness |
| [run.sh](run.sh) | Compiles the `bench` profile and runs the harness |
| [results/](results) | The unedited output of each suite. [results/before-group-commit/](results/before-group-commit) has the output of the first run. |

## Commands

```
make bench                        # every suite, about 20 minutes
bench/run.sh smoke                # one short run, to check the harness
bench/run.sh throughput reads     # the named suites
rebar3 as bench eunit             # the tests for peace_kv
```

The suites are `throughput`, `value_size`, `propose_to`, `reads`,
`failover`, `restart` and `catch_up`.

The environment variable `PEACE_BENCH_NODE_FLAGS` sets extra emulator flags
for the server nodes.

## Method

- Each server runs on a separate Erlang node. The harness starts the nodes
  with the `peer` module. All nodes run on one machine.
- The clients are processes on a controller node. The clients reach the
  servers over Erlang distribution.
- The clients are closed-loop. A client sends one request, waits for the
  answer, and then sends the next request.
- A load run has a warm-up of 2 s and a measurement of 10 s. A request is
  counted if it started after the warm-up and was answered before the end
  of the measurement.
- A request uses a key chosen uniformly from 1000 keys. A value is 100
  random bytes, unless the table states another size.
- The clients do not use sessions.
- The dets backend and the write-ahead log backend store their files in
  `_build/bench/data`, on the internal disk.
- The cluster options are the defaults, unless the table states another
  value. The election timeout is 1000 ms, the heartbeat interval is 200 ms
  and the snapshot interval is 4096 indexes.
- A recovery test stops a server by calling `erlang:halt/2` on the node of
  the server. The server does not close its storage.

Environment:

| Item | Value |
|---|---|
| Machine | Apple M4, 10 cores, 32 GB of memory |
| Operating system | macOS 26.5.1 |
| Erlang | OTP 28, ERTS 16.2, default emulator flags |
| peace | commit `669cffa` plus group commit and `peace_storage_wal` |

## Results

"mem" is `peace_storage_mem`, which stores nothing. "dets" is
`peace_storage_dets`. "wal" is `peace_storage_wal`, the default backend.
Both durable backends sync on every write. `peace_server` performs one write
for each group of events that are waiting in its mailbox.

### Writes

Source: [results/throughput.txt](results/throughput.txt). Every request is
a put.

| Servers | Storage | Clients | Requests/s | p50 ms | p95 ms | p99 ms | Max ms |
|---|---|---|---|---|---|---|---|
| 3 | mem | 1 | 17,522 | 0.06 | 0.06 | 0.15 | 2.95 |
| 3 | mem | 4 | 48,369 | 0.07 | 0.13 | 0.34 | 0.89 |
| 3 | mem | 16 | 63,143 | 0.21 | 0.49 | 0.60 | 2.80 |
| 3 | mem | 64 | 31,633 | 1.94 | 2.99 | 3.34 | 7.77 |
| 3 | mem | 256 | 11,300 | 22.6 | 30.8 | 36.5 | 43.4 |
| 5 | mem | 1 | 14,367 | 0.07 | 0.08 | 0.25 | 0.50 |
| 5 | mem | 4 | 35,311 | 0.10 | 0.27 | 0.39 | 0.66 |
| 5 | mem | 16 | 39,997 | 0.36 | 0.67 | 0.77 | 1.19 |
| 5 | mem | 64 | 23,134 | 2.67 | 4.03 | 4.62 | 14.7 |
| 5 | mem | 256 | 8,857 | 29.5 | 35.4 | 39.2 | 52.4 |
| 3 | dets | 1 | 360 | 1.89 | 7.20 | 12.6 | 98.6 |
| 3 | dets | 4 | 858 | 3.99 | 7.22 | 21.2 | 152.1 |
| 3 | dets | 16 | 1,945 | 7.37 | 10.3 | 28.2 | 158.9 |
| 3 | dets | 64 | 3,671 | 15.6 | 26.7 | 105.7 | 112.5 |
| 3 | dets | 256 | 4,100 | 56.9 | 125.5 | 145.7 | 164.6 |
| 5 | dets | 1 | 253 | 2.91 | 8.57 | 24.7 | 68.8 |
| 5 | dets | 4 | 439 | 7.36 | 18.4 | 36.7 | 203.3 |
| 5 | dets | 16 | 1,201 | 10.8 | 24.1 | 60.6 | 262.3 |
| 5 | dets | 64 | 2,351 | 23.6 | 37.8 | 216.5 | 282.0 |
| 5 | dets | 256 | 2,782 | 79.9 | 258.8 | 284.7 | 293.2 |
| 3 | wal | 1 | 1,754 | 0.49 | 0.85 | 1.03 | 19.0 |
| 3 | wal | 4 | 2,697 | 1.37 | 2.52 | 3.79 | 23.2 |
| 3 | wal | 16 | 7,681 | 1.86 | 2.96 | 6.32 | 207.6 |
| 3 | wal | 64 | 15,815 | 3.52 | 6.74 | 13.5 | 325.5 |
| 3 | wal | 256 | 8,649 | 30.0 | 37.1 | 44.7 | 55.6 |
| 5 | wal | 1 | 1,366 | 0.64 | 1.01 | 3.19 | 18.3 |
| 5 | wal | 4 | 1,934 | 1.76 | 4.08 | 8.57 | 26.6 |
| 5 | wal | 16 | 5,729 | 2.53 | 4.34 | 10.9 | 26.5 |
| 5 | wal | 64 | 7,734 | 5.54 | 18.2 | 25.7 | 314.9 |
| 5 | wal | 256 | 6,781 | 37.8 | 45.6 | 55.2 | 64.8 |

No request failed in any load run.

### Value size

Source: [results/value_size.txt](results/value_size.txt). 3 servers, 16
clients. Every request is a put.

| Storage | Value bytes | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | 100 | 64,454 | 0.20 | 0.57 |
| mem | 1,000 | 54,673 | 0.27 | 0.58 |
| mem | 10,000 | 44,280 | 0.34 | 0.70 |
| mem | 100,000 | 22,950 | 0.67 | 1.29 |
| dets | 100 | 1,814 | 7.86 | 28.8 |
| dets | 1,000 | 1,574 | 8.09 | 77.3 |
| dets | 10,000 | 1,332 | 9.20 | 132.7 |
| dets | 100,000 | 632 | 17.1 | 337.7 |
| wal | 100 | 8,015 | 1.90 | 6.58 |
| wal | 1,000 | 4,802 | 2.37 | 16.1 |
| wal | 10,000 | 4,644 | 2.48 | 19.6 |
| wal | 100,000 | 1,659 | 7.18 | 105.2 |

### Proposing to a phase-two quorum

Source: [results/propose_to.txt](results/propose_to.txt). 5 servers, 16
clients. Every request is a put.

| Storage | Quorum system | `propose_to` | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|---|
| mem | `majority` | `all` | 39,917 | 0.36 | 0.77 |
| mem | `majority` | `quorum` | 53,469 | 0.24 | 0.70 |
| mem | `{counting, 4, 2}` | `all` | 41,545 | 0.34 | 0.76 |
| mem | `{counting, 4, 2}` | `quorum` | 74,928 | 0.16 | 0.58 |
| wal | `majority` | `all` | 5,755 | 2.61 | 11.3 |
| wal | `majority` | `quorum` | 7,473 | 2.03 | 5.86 |
| wal | `{counting, 4, 2}` | `all` | 6,125 | 2.46 | 9.35 |
| wal | `{counting, 4, 2}` | `quorum` | 10,484 | 1.41 | 3.92 |

With `propose_to => quorum`, throughput is 30% to 34% higher with
`majority` and 71% to 80% higher with `{counting, 4, 2}`.

### Reads

Source: [results/reads.txt](results/reads.txt). 3 servers, 16 clients.

| Storage | Read | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | `peace_kv:get`, a proposed value | 81,452 | 0.19 | 0.29 |
| mem | `consistent_query`, no lease | 76,085 | 0.21 | 0.31 |
| mem | `local_query` | 176,054 | 0.08 | 0.15 |
| mem | `consistent_query`, `read_lease_ms => 1000` | 178,011 | 0.08 | 0.15 |
| wal | `peace_kv:get`, a proposed value | 8,369 | 1.79 | 4.57 |
| wal | `consistent_query`, no lease | 8,356 | 1.80 | 4.36 |
| wal | `local_query` | 179,383 | 0.08 | 0.16 |
| wal | `consistent_query`, `read_lease_ms => 1000` | 175,812 | 0.08 | 0.15 |

A `consistent_query` under a read lease costs the same as a `local_query`.
Without a lease, a `consistent_query` costs the same as a write.

### Leader failure

Source: [results/failover.txt](results/failover.txt). wal storage. The
harness kills the node of the leader. The result is the time from the kill
to the first answered put that was sent after the kill. Each row has 10
trials.

| Servers | Election timeout ms | Min ms | Median ms | Max ms |
|---|---|---|---|---|
| 3 | 1000 | 1423.4 | 1722.4 | 1881.6 |
| 3 | 100 | 122.5 | 158.2 | 192.3 |
| 5 | 1000 | 1048.6 | 1467.0 | 1739.8 |
| 5 | 100 | 110.9 | 165.2 | 183.8 |

Every trial is between 1 and 2 election timeouts. A follower starts an
election between T and 2T after the last message from the leader, where T
is the election timeout.

### Restart from a snapshot

Source: [results/restart.txt](results/restart.txt). 3 servers,
`snapshot_interval => 64`. The harness loads the machine state with 64 kB
values, kills the node of a follower, starts the node again and starts the
server. No value is proposed while the follower is down.

| Storage | Machine state | Log entries above the snapshot | Server start ms | Caught up ms | Files MB |
|---|---|---|---|---|---|
| dets | 1 MB | 18 | 9.16 | 9.96 | 2.1 |
| dets | 10 MB | 32 | 11.0 | 11.8 | 24.0 |
| dets | 100 MB | 51 | 24.5 | 25.4 | 224.8 |
| wal | 1 MB | 18 | 4.79 | 5.56 | 2.0 |
| wal | 10 MB | 32 | 7.14 | 7.95 | 11.9 |
| wal | 100 MB | 56 | 25.8 | 26.7 | 103.7 |

"Server start" is the time for `peace:start_server/1` to return. The server
has then read its files and applied its log. "Caught up" is the time until
the commit index of the follower equals the commit index of the leader. Both
times start when `peace:start_server/1` is called. The time to start the
Erlang node is not included.

### Catch-up

Source: [results/catch_up.txt](results/catch_up.txt). 3 servers, wal
storage, 1000-byte values. The harness kills the node of a follower,
proposes a number of values, and restarts the follower. No value is
proposed while the follower catches up. The result is the time from
`peace:start_server/1` until the commit index of the follower equals the
commit index of the leader.

| Heartbeat ms | Values missed | Transferred as | Caught up ms |
|---|---|---|---|
| 200 | 100 | log entries | 449.8 |
| 200 | 1,000 | log entries | 3301.2 |
| 200 | 3,000 | log entries | 9488.7 |
| 200 | 10,000 | snapshot | 308.9 |
| 20 | 100 | log entries | 40.5 |
| 20 | 1,000 | log entries | 327.8 |
| 20 | 3,000 | log entries | 983.9 |
| 20 | 10,000 | snapshot | 25.9 |

With 10,000 missed values the leader has taken a snapshot and deleted the
log entries, so the leader sends its machine state.

### Comparison with the first run

The first run measured commit `fafe21d`, before group commit and before the
write-ahead log. Its output is in
[results/before-group-commit/](results/before-group-commit). The table
compares puts on 3 servers.

| Storage | Clients | Requests/s before | Requests/s now |
|---|---|---|---|
| dets | 1 | 338 | 360 |
| dets | 16 | 479 | 1,945 |
| dets | 64 | 512 | 3,671 |
| dets | 256 | 499 | 4,100 |
| wal | 16 | not available | 7,681 |
| wal | 64 | not available | 15,815 |
| mem | 16 | 67,114 | 63,143 |
| mem | 64 | 58,167 | 31,633 |
| mem | 256 | 15,499 | 11,300 |

- With dets and 256 clients, group commit raises throughput by a factor of
  8.
- With 64 clients, the write-ahead log is 31 times faster than dets was in
  the first run.
- With mem and 64 clients, throughput is 46% lower than in the first run.
  See bottleneck 1.

## Bottlenecks

1. **Throughput falls when many values are undecided.** With mem and 3
   servers, throughput is 63,143 requests/s with 16 clients and 11,300
   requests/s with 256 clients. With wal, throughput is 15,815 requests/s
   with 64 clients and 8,649 requests/s with 256 clients. A probable cause
   is `settle/1` in `peace_core`. The leader calls `settle/1` for each value
   and for each `accept` message. `settle/1` sorts every undecided index and
   tests each for a quorum, so the cost of one event grows with the number
   of undecided indexes. Group commit makes this worse for mem: the leader
   handles a group of values before it handles the `accept` messages for
   them, so more indexes are undecided at once. This cause was found by
   reading the code. It was not confirmed with a profiler. The item is in
   milestone 4.
2. **Storage: one sync per group of events.** With wal, one client gets
   1,754 requests/s, and 16 clients get 7,681 requests/s. With mem the
   figures are 17,522 and 63,143. The difference is the cost of the syncs.
   A value needs a sync on the leader and a sync on each acceptor of a
   phase-two quorum before the client is answered.
3. **One `propose` message per value.** The leader sends one message to each
   acceptor for each value. The leader does not combine values that arrive
   together. Batching is planned in milestone 4.
4. **Catch-up from the log is limited by the heartbeat.** A follower
   requests missing entries only when it receives a `propose` message. One
   request returns at most 64 entries. On an idle cluster the follower
   therefore receives 64 entries per heartbeat interval: 320 entries/s with
   the default heartbeat of 200 ms. 3000 missed values take 9.5 s. A
   snapshot of 10,000 values takes 0.31 s. The item is in milestone 4.
5. **Leader failure is detected only by the election timeout.** The time
   without a leader is between 1 and 2 election timeouts. A lower election
   timeout shortens the time in proportion.
6. **Large values with wal.** With 100 kB values, wal gets 1,659 requests/s
   and mem gets 22,950 requests/s.

No bottleneck was found in restart from a snapshot at the sizes tested.

## Limitations

- All nodes run on one machine. The results contain no network latency and
  no network bandwidth limit. The servers, the clients and the disk share
  10 cores and one disk.
- The dets and wal results depend on the cost of a sync on this disk. The cost was
  not measured separately. The results do not transfer to another disk.
- Each configuration was run once. The variance between runs was not
  measured.
- The clients are closed-loop. A closed-loop client sends no request while
  it waits, so the latency figures understate the latency that an open
  workload with the same request rate would observe.
- The restart test reads files that the operating system has in its page
  cache. A restart after a reboot of the machine reads the file from
  disk and takes longer.
- The largest machine state tested is 100 MB. The largest value tested is
  100 kB.
- The leader failure test kills the node. The other nodes observe a closed
  connection. A network partition and a paused process were not tested.
- Membership change under load was not measured.
- The output of the second run contains warnings from `global` about
  overlapping partitions. `global` printed them when the harness stopped the
  nodes of one cluster and started the nodes of the next. No request failed.
  The harness now starts every node with
  `-kernel prevent_overlapping_partitions false`.
