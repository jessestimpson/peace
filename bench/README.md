# Benchmarks

This directory contains a key-value state machine, a benchmark harness, and
the results of the benchmark runs of 2026-11-12. The benchmark is milestone 1
of [ROADMAP.md](../ROADMAP.md). It was repeated for milestone 2, with group
commit and the write-ahead log backend, and twice for milestone 4, with the
changes that "Comparison with the earlier runs" lists. The results below
are from the fourth run.

## Source layout

| File | Contents |
|---|---|
| [peace_kv.erl](peace_kv.erl) | A key-value state machine and a client for it: put, get, delete, compare-and-swap |
| [peace_kv_tests.erl](peace_kv_tests.erl) | Tests for `peace_kv` |
| [peace_bench.erl](peace_bench.erl) | The benchmark harness |
| [run.sh](run.sh) | Compiles the `bench` profile and runs the harness |
| [results/](results) | The unedited output of each suite. [results/before-group-commit/](results/before-group-commit) has the output of the first run. [results/before-milestone-4/](results/before-milestone-4) has the output of the second run. [results/before-storage-process/](results/before-storage-process) has the output of the third run. |

## Commands

```
make bench                        # every suite, about 20 minutes
bench/run.sh smoke                # one short run, to check the harness
bench/run.sh quick                # puts on 3 servers with mem and wal, about 2 minutes
bench/run.sh slow_disk            # puts on 3 servers where one server has a slow disk
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
| peace | commit `108b55c` for most suites. The suites `throughput` and `slow_disk` were run with changes 9 and 10 of "Comparison with the earlier runs". |

## Results

"mem" is `peace_storage_mem`, which stores nothing. "dets" is
`peace_storage_dets`. "wal" is `peace_storage_wal`, the default backend.
Both durable backends sync every write that contains a promise, a proposal
or a snapshot. `peace_server` sends one write for each group of events
that are waiting in its mailbox to its storage process, `peace_writer`.
The storage process merges the writes that are waiting in its own mailbox
into one call to the backend.

### Writes

Source: [results/throughput.txt](results/throughput.txt). Every request is
a put.

| Servers | Storage | Clients | Requests/s | p50 ms | p95 ms | p99 ms | Max ms |
|---|---|---|---|---|---|---|---|
| 3 | mem | 1 | 16,555 | 0.06 | 0.07 | 0.23 | 1.00 |
| 3 | mem | 4 | 49,586 | 0.07 | 0.17 | 0.34 | 0.68 |
| 3 | mem | 16 | 88,566 | 0.15 | 0.39 | 0.47 | 0.95 |
| 3 | mem | 64 | 106,167 | 0.58 | 0.92 | 1.06 | 1.52 |
| 3 | mem | 256 | 110,799 | 2.24 | 3.27 | 3.62 | 4.90 |
| 5 | mem | 1 | 13,779 | 0.07 | 0.08 | 0.26 | 0.64 |
| 5 | mem | 4 | 36,461 | 0.09 | 0.26 | 0.39 | 0.77 |
| 5 | mem | 16 | 62,284 | 0.22 | 0.49 | 0.57 | 0.94 |
| 5 | mem | 64 | 78,295 | 0.79 | 1.26 | 1.46 | 2.64 |
| 5 | mem | 256 | 91,908 | 2.75 | 3.87 | 4.30 | 5.75 |
| 3 | dets | 1 | 582 | 1.32 | 3.22 | 7.06 | 132.5 |
| 3 | dets | 4 | 1,141 | 2.89 | 5.61 | 10.3 | 140.9 |
| 3 | dets | 16 | 3,563 | 3.74 | 5.03 | 15.1 | 143.3 |
| 3 | dets | 64 | 6,246 | 7.98 | 10.8 | 130.4 | 148.6 |
| 3 | dets | 256 | 7,597 | 25.9 | 135.7 | 156.8 | 175.7 |
| 5 | dets | 1 | 316 | 2.25 | 7.03 | 19.6 | 246.6 |
| 5 | dets | 4 | 528 | 5.61 | 14.1 | 42.1 | 249.3 |
| 5 | dets | 16 | 1,547 | 5.89 | 21.7 | 76.0 | 306.3 |
| 5 | dets | 64 | 3,508 | 14.0 | 18.4 | 256.6 | 264.5 |
| 5 | dets | 256 | 4,141 | 47.4 | 272.6 | 294.3 | 305.5 |
| 3 | wal | 1 | 2,323 | 0.34 | 0.80 | 1.18 | 231.8 |
| 3 | wal | 4 | 4,723 | 0.72 | 1.64 | 2.09 | 18.6 |
| 3 | wal | 16 | 15,602 | 0.91 | 1.67 | 3.75 | 20.0 |
| 3 | wal | 64 | 30,726 | 1.41 | 4.98 | 6.86 | 291.2 |
| 3 | wal | 256 | 58,299 | 3.31 | 6.70 | 13.7 | 303.2 |
| 5 | wal | 1 | 1,880 | 0.46 | 0.83 | 1.49 | 45.1 |
| 5 | wal | 4 | 3,233 | 0.97 | 2.58 | 5.62 | 44.1 |
| 5 | wal | 16 | 10,170 | 1.35 | 2.39 | 6.63 | 278.4 |
| 5 | wal | 64 | 14,197 | 2.41 | 8.41 | 14.2 | 326.9 |
| 5 | wal | 256 | 35,124 | 4.72 | 11.4 | 33.8 | 261.6 |

No request failed in any load run.

### One shared disk

All nodes of this benchmark store their files on one disk. The table shows
the number of syncs that the disk performs when several files are written
and synced at the same time, with no peace code involved. Each writer
appends 200 bytes and calls `file:datasync/1`, for 3 seconds.

| Files | Syncs/s in total | Syncs/s per file | ms per sync |
|---|---|---|---|
| 1 | 7,259 | 7,259 | 0.14 |
| 2 | 8,004 | 4,002 | 0.25 |
| 3 | 7,426 | 2,475 | 0.40 |
| 5 | 8,465 | 1,693 | 0.59 |
| 8 | 8,852 | 1,106 | 0.90 |

The disk performs about the same number of syncs in total for any number
of files. Three servers get about 2,500 syncs/s each. Five servers get
about 1,700 syncs/s each. This is the main reason that 5 servers with wal
are slower than 3 servers with wal in this benchmark. Servers with separate
disks do not share a sync budget in this way.

The disk also stops for 50 ms to 300 ms a few times in 10 seconds. During
such a stop, a sync takes that long on every node at the same time. The
maximum latencies with wal in the table above are these stops. The stops
are not related to snapshots. A test that only appends and syncs files did
not reproduce them at this rate, and their cause is not known. A phase-two
quorum cannot hide a stop that affects every node.

The throughput of one configuration varies between runs because of these
stops. Five servers with wal and 64 clients gave 10,703, 14,197, 15,769,
17,302, 17,728 and 18,678 requests/s in six runs.

### One slow disk

Source: [results/slow_disk.txt](results/slow_disk.txt). 3 servers, wal
storage. Every sync on the slow server takes 20 ms longer.

| Slow server | Clients | Requests/s | p50 ms | p99 ms | Max ms |
|---|---|---|---|---|---|
| none | 1 | 2,515 | 0.33 | 0.92 | 15.7 |
| none | 16 | 15,396 | 0.94 | 2.77 | 26.0 |
| a follower | 1 | 3,067 | 0.28 | 0.61 | 14.3 |
| a follower | 16 | 17,243 | 0.76 | 4.10 | 294.2 |
| the leader | 1 | 3,172 | 0.27 | 0.61 | 14.3 |
| the leader | 16 | 18,378 | 0.79 | 2.11 | 24.7 |
| all servers | 1 | 42 | 22.0 | 43.4 | 51.7 |
| all servers | 16 | 392 | 42.5 | 55.2 | 141.7 |

One slow disk does not raise the latency, whether the slow server is a
follower or the leader. A value is decided when a phase-two quorum has
stored it, and the two other servers are a phase-two quorum. The leader
does not wait for its own write. The throughput is higher with one slow
server, because the two other servers then share the disk between two and
not three.

### Value size

Source: [results/value_size.txt](results/value_size.txt). 3 servers, 16
clients. Every request is a put.

| Storage | Value bytes | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | 100 | 86,800 | 0.15 | 0.48 |
| mem | 1,000 | 72,258 | 0.19 | 0.51 |
| mem | 10,000 | 38,083 | 0.41 | 0.72 |
| mem | 100,000 | 20,236 | 0.78 | 1.40 |
| dets | 100 | 3,505 | 3.67 | 25.4 |
| dets | 1,000 | 3,299 | 3.86 | 24.8 |
| dets | 10,000 | 2,305 | 4.18 | 57.1 |
| dets | 100,000 | 859 | 11.0 | 265.5 |
| wal | 100 | 15,316 | 0.93 | 4.13 |
| wal | 1,000 | 6,496 | 1.22 | 7.64 |
| wal | 10,000 | 7,536 | 1.35 | 11.7 |
| wal | 100,000 | 2,087 | 3.93 | 179.7 |

### Proposing to a phase-two quorum

Source: [results/propose_to.txt](results/propose_to.txt). 5 servers, 16
clients. Every request is a put.

| Storage | Quorum system | `propose_to` | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|---|
| mem | `majority` | `all` | 64,280 | 0.21 | 0.57 |
| mem | `majority` | `quorum` | 74,706 | 0.17 | 0.58 |
| mem | `{counting, 4, 2}` | `all` | 61,677 | 0.23 | 0.59 |
| mem | `{counting, 4, 2}` | `quorum` | 89,789 | 0.14 | 0.52 |
| wal | `majority` | `all` | 10,017 | 1.43 | 7.61 |
| wal | `majority` | `quorum` | 12,629 | 1.13 | 4.96 |
| wal | `{counting, 4, 2}` | `all` | 9,657 | 1.27 | 8.80 |
| wal | `{counting, 4, 2}` | `quorum` | 16,829 | 0.74 | 4.13 |

With `propose_to => quorum`, throughput is 9% to 20% higher with
`majority` and with `{counting, 4, 2}`. See the table for the amounts.

### Reads

Source: [results/reads.txt](results/reads.txt). 3 servers, 16 clients.

| Storage | Read | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | `peace_kv:get`, a proposed value | 103,452 | 0.15 | 0.27 |
| mem | `consistent_query`, no lease | 101,954 | 0.15 | 0.27 |
| mem | `local_query` | 156,147 | 0.09 | 0.17 |
| mem | `consistent_query`, `read_lease_ms => 1000` | 162,148 | 0.09 | 0.16 |
| wal | `peace_kv:get`, a proposed value | 16,862 | 0.85 | 2.98 |
| wal | `consistent_query`, no lease | 16,844 | 0.84 | 3.02 |
| wal | `local_query` | 151,747 | 0.10 | 0.17 |
| wal | `consistent_query`, `read_lease_ms => 1000` | 158,420 | 0.09 | 0.17 |

A `consistent_query` under a read lease costs the same as a `local_query`.
Without a lease, a `consistent_query` costs the same as a write.

### Leader failure

Source: [results/failover.txt](results/failover.txt). wal storage. The
harness kills the node of the leader. The result is the time from the kill
to the first answered put that was sent after the kill. Each row has 10
trials.

| Servers | Election timeout ms | Min ms | Median ms | Max ms |
|---|---|---|---|---|
| 3 | 1000 | 1275.1 | 1632.9 | 1884.9 |
| 3 | 100 | 108.3 | 157.3 | 198.5 |
| 5 | 1000 | 1213.0 | 1395.1 | 1872.4 |
| 5 | 100 | 130.0 | 153.9 | 193.0 |

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
| dets | 1 MB | 18 | 19.1 | 274.0 | 2.0 |
| dets | 10 MB | 34 | 37.0 | 37.9 | 12.3 |
| dets | 100 MB | 54 | 214.6 | 271.9 | 134.8 |
| wal | 1 MB | 18 | 5.24 | 5.97 | 2.0 |
| wal | 10 MB | 31 | 7.94 | 8.78 | 11.9 |
| wal | 100 MB | 55 | 26.4 | 27.3 | 103.5 |

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
| 200 | 100 | log entries | 273.4 |
| 200 | 1,000 | log entries | 205.3 |
| 200 | 3,000 | log entries | 388.8 |
| 200 | 10,000 | snapshot | 310.0 |
| 20 | 100 | log entries | 15.3 |
| 20 | 1,000 | log entries | 13.8 |
| 20 | 3,000 | log entries | 29.3 |
| 20 | 10,000 | snapshot | 22.5 |

With 10,000 missed values the leader has taken a snapshot and deleted the
log entries, so the leader sends its machine state.

### Comparison with the earlier runs

| Run | peace | Output |
|---|---|---|
| First | commit `fafe21d`, before group commit and before the write-ahead log | [results/before-group-commit/](results/before-group-commit) |
| Second | commit `669cffa` plus group commit and `peace_storage_wal` | [results/before-milestone-4/](results/before-milestone-4) |
| Third | commit `c4854fd` plus changes 1 to 7 below (commit `abd6037`) | [results/before-storage-process/](results/before-storage-process) |
| Fourth | commit `abd6037` plus change 8 below | [results/](results) |

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
8. Storage writes are performed by a separate process, `peace_writer`. A
   server handles events while a write is in progress. A leader counts its
   own acceptance only after the write has returned.
9. `peace_writer` merges every write that waits in its mailbox into one
   call. It merged at most 64. With a slow disk on the leader, the writes
   that waited grew without bound, and throughput with 16 clients was 3,705
   requests/s with stops of up to 859 ms. It is now 18,378 requests/s.
10. A server does not wait for the write of a snapshot. With a slow disk on
    the leader, each snapshot stopped the leader for about 130 ms.

The table compares puts on 3 servers.

| Storage | Clients | Second run: requests/s | Third run: requests/s | Fourth run: requests/s | Second run: p50 ms | Third run: p50 ms | Fourth run: p50 ms |
|---|---|---|---|---|---|---|---|
| mem | 1 | 17,522 | 17,728 | 16,555 | 0.06 | 0.05 | 0.06 |
| mem | 16 | 63,143 | 92,702 | 88,566 | 0.21 | 0.14 | 0.15 |
| mem | 64 | 31,633 | 118,459 | 106,167 | 1.94 | 0.51 | 0.58 |
| mem | 256 | 11,300 | 121,385 | 110,799 | 22.6 | 2.03 | 2.24 |
| wal | 1 | 1,754 | 2,354 | 2,323 | 0.49 | 0.35 | 0.34 |
| wal | 4 | 2,697 | 3,773 | 4,723 | 1.37 | 0.99 | 0.72 |
| wal | 16 | 7,681 | 11,402 | 15,602 | 1.86 | 1.29 | 0.91 |
| wal | 64 | 15,815 | 25,249 | 30,726 | 3.52 | 1.72 | 1.41 |
| wal | 256 | 8,649 | 48,684 | 58,299 | 30.0 | 3.49 | 3.31 |

The fourth-run figures in this table are from the `throughput` suite with
changes 9 and 10.

- Changes 1 to 3 removed the fall in throughput when the number of clients
  rises. With mem and 256 clients, throughput in the third run is 10.7
  times the second run.
- Changes 4 to 6 reduced the number of syncs that a put waits for. With wal
  and 1 client, the median latency is 0.34 ms instead of 0.49 ms. A put
  waits for one sync on a phase-two quorum. It waited for a sync on the
  leader, then a sync on a follower, then a second sync on the leader.
- Change 8 lowered the latency with wal and 4 to 64 clients. With 16
  clients, the median latency is 0.91 ms instead of 1.29 ms, and the 99th
  percentile is 3.75 ms instead of 5.19 ms.
- Change 8 costs throughput with mem: 9% with 256 clients. Every group of
  events now takes two more messages between processes. The mem backend is
  for tests.
- Change 7 reduced the catch-up of 3,000 missed values from the log from
  9,489 ms to 389 ms, with a heartbeat of 200 ms.

## Bottlenecks

1. **Storage: one sync at a time.** With wal, one client gets 2,323
   requests/s. With mem, one client gets 16,555 requests/s. The difference
   is the cost of the sync on a phase-two quorum. With 16 clients the
   median latency is 0.91 ms and with 1 client it is 0.34 ms, because a
   write that arrives during a sync waits for that sync to end.
2. **All nodes share one disk.** See "One shared disk". Five servers with
   wal get less throughput than three, and the maximum latency with wal is
   up to 327 ms, because of the disk and not because of peace. This
   benchmark cannot measure either figure for servers with separate disks.
3. **Snapshots are needed for low latency.** With `snapshot_interval` set
   so high that no snapshot is taken, 3 servers with wal and 64 clients
   have a 99th percentile of 37.6 ms instead of 6.86 ms. The server process
   then holds the whole log, and its garbage collections take tens of
   milliseconds.
4. **No backpressure.** A leader accepts values without a bound. The
   storage process merges every write that waits, so the writes that wait
   are bounded by the arrivals during one sync. The values that wait for a
   decision are not bounded.
5. **Leader failure is detected only by the election timeout.** The time
   without a leader is between 1 and 2 election timeouts. A lower election
   timeout shortens the time in proportion.
6. **Large values with wal.** See "Value size".
7. **Restart with dets varies between runs.** In this run, the follower
   with 1 MB of state caught up after 274 ms, and the follower with 100 MB
   started in 215 ms. In the third run the figures were 17.7 ms and
   24.1 ms. The cause was not investigated.

No bottleneck was found in restart from a snapshot with wal at the sizes
tested.

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
