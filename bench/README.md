# Benchmarks

This directory contains a key-value state machine, a benchmark harness, and
the results of the benchmark runs of 2026-11-12. The benchmark is milestone 1
of [ROADMAP.md](../ROADMAP.md). It was repeated for milestone 2, with group
commit and the write-ahead log backend, and for milestone 4, with the
changes that "Comparison with the earlier runs" lists. The results below
are from the third run.

## Source layout

| File | Contents |
|---|---|
| [peace_kv.erl](peace_kv.erl) | A key-value state machine and a client for it: put, get, delete, compare-and-swap |
| [peace_kv_tests.erl](peace_kv_tests.erl) | Tests for `peace_kv` |
| [peace_bench.erl](peace_bench.erl) | The benchmark harness |
| [run.sh](run.sh) | Compiles the `bench` profile and runs the harness |
| [results/](results) | The unedited output of each suite. [results/before-group-commit/](results/before-group-commit) has the output of the first run. [results/before-milestone-4/](results/before-milestone-4) has the output of the second run. |

## Commands

```
make bench                        # every suite, about 20 minutes
bench/run.sh smoke                # one short run, to check the harness
bench/run.sh quick                # puts on 3 servers with mem and wal, about 2 minutes
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
| peace | commit `c4854fd` plus the changes of milestone 4 |

## Results

"mem" is `peace_storage_mem`, which stores nothing. "dets" is
`peace_storage_dets`. "wal" is `peace_storage_wal`, the default backend.
Both durable backends sync every write that contains a promise, a proposal
or a snapshot. `peace_server` performs one write for each group of events
that are waiting in its mailbox.

### Writes

Source: [results/throughput.txt](results/throughput.txt). Every request is
a put.

| Servers | Storage | Clients | Requests/s | p50 ms | p95 ms | p99 ms | Max ms |
|---|---|---|---|---|---|---|---|
| 3 | mem | 1 | 17,728 | 0.05 | 0.06 | 0.21 | 0.99 |
| 3 | mem | 4 | 50,720 | 0.07 | 0.13 | 0.33 | 4.98 |
| 3 | mem | 16 | 92,702 | 0.14 | 0.38 | 0.46 | 0.81 |
| 3 | mem | 64 | 118,459 | 0.51 | 0.83 | 0.95 | 1.50 |
| 3 | mem | 256 | 121,385 | 2.03 | 3.07 | 3.38 | 5.45 |
| 5 | mem | 1 | 14,062 | 0.07 | 0.08 | 0.26 | 8.21 |
| 5 | mem | 4 | 38,412 | 0.09 | 0.19 | 0.38 | 9.89 |
| 5 | mem | 16 | 67,048 | 0.20 | 0.46 | 0.55 | 0.93 |
| 5 | mem | 64 | 86,761 | 0.72 | 1.13 | 1.36 | 1.77 |
| 5 | mem | 256 | 99,219 | 2.53 | 3.61 | 4.02 | 5.62 |
| 3 | dets | 1 | 619 | 1.18 | 2.73 | 7.37 | 93.2 |
| 3 | dets | 4 | 1,857 | 1.60 | 3.78 | 7.51 | 98.8 |
| 3 | dets | 16 | 3,896 | 3.34 | 4.15 | 17.6 | 108.9 |
| 3 | dets | 64 | 5,776 | 8.43 | 14.3 | 100.5 | 118.1 |
| 3 | dets | 256 | 6,923 | 26.8 | 117.8 | 122.4 | 195.5 |
| 5 | dets | 1 | 319 | 2.26 | 7.59 | 16.3 | 208.7 |
| 5 | dets | 4 | 1,186 | 2.89 | 4.19 | 8.97 | 196.5 |
| 5 | dets | 16 | 2,408 | 5.48 | 6.72 | 18.3 | 197.6 |
| 5 | dets | 64 | 3,481 | 14.2 | 22.1 | 208.2 | 213.5 |
| 5 | dets | 256 | 3,994 | 48.9 | 241.2 | 245.3 | 255.3 |
| 3 | wal | 1 | 2,354 | 0.35 | 0.67 | 1.04 | 216.3 |
| 3 | wal | 4 | 3,773 | 0.99 | 1.96 | 2.90 | 18.4 |
| 3 | wal | 16 | 11,402 | 1.29 | 2.32 | 5.19 | 28.9 |
| 3 | wal | 64 | 25,249 | 1.72 | 6.07 | 9.87 | 318.3 |
| 3 | wal | 256 | 48,684 | 3.49 | 9.09 | 15.1 | 306.5 |
| 5 | wal | 1 | 1,965 | 0.45 | 0.75 | 1.36 | 18.0 |
| 5 | wal | 4 | 2,513 | 1.29 | 3.59 | 7.28 | 117.7 |
| 5 | wal | 16 | 7,627 | 1.86 | 3.29 | 10.4 | 27.4 |
| 5 | wal | 64 | 9,929 | 3.38 | 13.8 | 18.4 | 258.7 |
| 5 | wal | 256 | 28,615 | 4.96 | 14.7 | 125.6 | 261.8 |

No request failed in any load run.

### Value size

Source: [results/value_size.txt](results/value_size.txt). 3 servers, 16
clients. Every request is a put.

| Storage | Value bytes | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | 100 | 92,343 | 0.14 | 0.47 |
| mem | 1,000 | 76,693 | 0.18 | 0.49 |
| mem | 10,000 | 43,208 | 0.35 | 0.67 |
| mem | 100,000 | 22,204 | 0.70 | 1.32 |
| dets | 100 | 3,957 | 3.33 | 18.5 |
| dets | 1,000 | 3,326 | 3.92 | 22.2 |
| dets | 10,000 | 2,638 | 4.25 | 41.4 |
| dets | 100,000 | 850 | 10.3 | 301.8 |
| wal | 100 | 11,590 | 1.27 | 4.82 |
| wal | 1,000 | 6,760 | 1.57 | 9.86 |
| wal | 10,000 | 6,709 | 1.71 | 12.9 |
| wal | 100,000 | 1,487 | 6.21 | 175.8 |

### Proposing to a phase-two quorum

Source: [results/propose_to.txt](results/propose_to.txt). 5 servers, 16
clients. Every request is a put.

| Storage | Quorum system | `propose_to` | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|---|
| mem | `majority` | `all` | 70,100 | 0.20 | 0.53 |
| mem | `majority` | `quorum` | 76,495 | 0.16 | 0.57 |
| mem | `{counting, 4, 2}` | `all` | 67,897 | 0.20 | 0.55 |
| mem | `{counting, 4, 2}` | `quorum` | 93,242 | 0.13 | 0.52 |
| wal | `majority` | `all` | 7,661 | 1.94 | 8.77 |
| wal | `majority` | `quorum` | 9,193 | 1.55 | 7.00 |
| wal | `{counting, 4, 2}` | `all` | 8,516 | 1.72 | 8.82 |
| wal | `{counting, 4, 2}` | `quorum` | 15,599 | 0.94 | 3.42 |

With `propose_to => quorum`, throughput is 9% to 20% higher with
`majority` and 37% to 83% higher with `{counting, 4, 2}`.

### Reads

Source: [results/reads.txt](results/reads.txt). 3 servers, 16 clients.

| Storage | Read | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | `peace_kv:get`, a proposed value | 107,978 | 0.14 | 0.23 |
| mem | `consistent_query`, no lease | 105,395 | 0.15 | 0.24 |
| mem | `local_query` | 167,214 | 0.09 | 0.16 |
| mem | `consistent_query`, `read_lease_ms => 1000` | 171,564 | 0.08 | 0.15 |
| wal | `peace_kv:get`, a proposed value | 11,953 | 1.23 | 3.57 |
| wal | `consistent_query`, no lease | 12,188 | 1.21 | 3.15 |
| wal | `local_query` | 170,008 | 0.08 | 0.17 |
| wal | `consistent_query`, `read_lease_ms => 1000` | 170,638 | 0.08 | 0.15 |

A `consistent_query` under a read lease costs the same as a `local_query`.
Without a lease, a `consistent_query` costs the same as a write. With wal,
the leader answers a `consistent_query` without a lease only after the
write of the group that the query is in.

### Leader failure

Source: [results/failover.txt](results/failover.txt). wal storage. The
harness kills the node of the leader. The result is the time from the kill
to the first answered put that was sent after the kill. Each row has 10
trials.

| Servers | Election timeout ms | Min ms | Median ms | Max ms |
|---|---|---|---|---|
| 3 | 1000 | 1184.1 | 1554.1 | 1893.5 |
| 3 | 100 | 120.7 | 144.6 | 205.6 |
| 5 | 1000 | 1113.2 | 1424.8 | 1818.8 |
| 5 | 100 | 114.1 | 142.9 | 167.1 |

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
| dets | 1 MB | 18 | 16.9 | 17.7 | 2.0 |
| dets | 10 MB | 34 | 35.5 | 36.3 | 12.3 |
| dets | 100 MB | 1 | 24.1 | 25.0 | 228.0 |
| wal | 1 MB | 18 | 5.05 | 5.85 | 2.0 |
| wal | 10 MB | 34 | 6.96 | 7.73 | 11.9 |
| wal | 100 MB | 43 | 25.9 | 26.9 | 102.5 |

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
| 200 | 100 | log entries | 261.1 |
| 200 | 1,000 | log entries | 233.6 |
| 200 | 3,000 | log entries | 353.2 |
| 200 | 10,000 | snapshot | 281.9 |
| 20 | 100 | log entries | 5.86 |
| 20 | 1,000 | log entries | 9.24 |
| 20 | 3,000 | log entries | 25.8 |
| 20 | 10,000 | snapshot | 27.7 |

With 10,000 missed values the leader has taken a snapshot and deleted the
log entries, so the leader sends its machine state.

### Comparison with the earlier runs

| Run | peace | Output |
|---|---|---|
| First | commit `fafe21d`, before group commit and before the write-ahead log | [results/before-group-commit/](results/before-group-commit) |
| Second | commit `669cffa` plus group commit and `peace_storage_wal` | [results/before-milestone-4/](results/before-milestone-4) |
| Third | commit `c4854fd` plus the changes of milestone 4 | [results/](results) |

The changes of milestone 4 are:

1. `settle` in `peace_core` tests only the indexes whose acknowledgements
   changed. It tested every undecided index for each event.
2. `peace_server` merges the storage batches of a group in linear time. The
   merge was quadratic in the size of the group.
3. `peace_server` sends one `propose` message and one `accept` message to a
   peer for a group of events. It sent one message for each value.
4. A leader sends its proposals before its own storage write.
5. A write that contains only `learned` entries is not synced.
6. A leader answers a client before the write of the group, if the answer
   does not depend on the write.
7. A follower that receives a full batch of decided entries requests the
   next batch at once.

The table compares puts on 3 servers.

| Storage | Clients | First run: requests/s | Second run: requests/s | Third run: requests/s | Second run: p50 ms | Third run: p50 ms |
|---|---|---|---|---|---|---|
| mem | 1 | 17,324 | 17,522 | 17,728 | 0.06 | 0.05 |
| mem | 16 | 67,114 | 63,143 | 92,702 | 0.21 | 0.14 |
| mem | 64 | 58,167 | 31,633 | 118,459 | 1.94 | 0.51 |
| mem | 256 | 15,499 | 11,300 | 121,385 | 22.6 | 2.03 |
| dets | 16 | 479 | 1,945 | 3,896 | 7.37 | 3.34 |
| dets | 256 | 499 | 4,100 | 6,923 | 56.9 | 26.8 |
| wal | 1 | not available | 1,754 | 2,354 | 0.49 | 0.35 |
| wal | 16 | not available | 7,681 | 11,402 | 1.86 | 1.29 |
| wal | 64 | not available | 15,815 | 25,249 | 3.52 | 1.72 |
| wal | 256 | not available | 8,649 | 48,684 | 30.0 | 3.49 |

- Throughput no longer falls when the number of clients rises. With mem
  and 256 clients, throughput is 10.7 times the second run, and the median
  latency is 2.03 ms instead of 22.6 ms.
- With wal and 1 client, the median latency is 0.35 ms instead of 0.49 ms.
  A put now waits for one sync on a phase-two quorum. It waited for a sync
  on the leader, then a sync on a follower, then a second sync on the
  leader.
- Catch-up of 3,000 missed values from the log takes 353 ms instead of
  9,489 ms, with a heartbeat of 200 ms.

## Bottlenecks

1. **The leader does not handle events while it syncs.** With wal and 16
   clients, the median latency is 1.29 ms. With 1 client it is 0.35 ms. A
   value that arrives during a write waits for that write. The `accept`
   message for the value then waits for the next write of the leader. A
   storage process that is separate from the server process would remove
   both waits. The item is in milestone 4.
2. **Storage: one sync per group of events.** With wal, one client gets
   2,354 requests/s. With mem, one client gets 17,728 requests/s. The
   difference is the cost of the sync on a phase-two quorum.
3. **Five servers with wal.** With 64 clients, 5 servers get 9,929
   requests/s and 3 servers get 25,249 requests/s. The 15 nodes and
   clients of this benchmark share one disk, so the result may not hold
   for servers with separate disks. The cause was not investigated.
4. **Tail latency with wal.** The maximum latency with wal is between 18 ms
   and 318 ms. The 99th percentile is between 1.04 ms and 15.1 ms for 3
   servers. The cause was not investigated. A probable cause is the
   checkpoint that the write-ahead log writes for each snapshot, which
   blocks the server.
5. **Leader failure is detected only by the election timeout.** The time
   without a leader is between 1 and 2 election timeouts. A lower election
   timeout shortens the time in proportion.
6. **Large values with wal.** With 100 kB values, wal gets 1,487 requests/s
   and mem gets 22,204 requests/s.

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
