# Benchmarks

This directory contains a key-value state machine, a benchmark harness, and
the results of the benchmark run of 2026-11-12. The benchmark is milestone 1
of [ROADMAP.md](../ROADMAP.md).

## Source layout

| File | Contents |
|---|---|
| [peace_kv.erl](peace_kv.erl) | A key-value state machine and a client for it: put, get, delete, compare-and-swap |
| [peace_kv_tests.erl](peace_kv_tests.erl) | Tests for `peace_kv` |
| [peace_bench.erl](peace_bench.erl) | The benchmark harness |
| [run.sh](run.sh) | Compiles the `bench` profile and runs the harness |
| [results/](results) | The unedited output of each suite |

## Commands

```
make bench                        # every suite, about 15 minutes
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
- The dets backend stores its files in `_build/bench/data`, on the internal
  disk.
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
| peace | commit `fafe21d` plus this directory |

## Results

"mem" is `peace_storage_mem`, which stores nothing. "dets" is
`peace_storage_dets`, which syncs the file on every write.

### Writes

Source: [results/throughput.txt](results/throughput.txt). Every request is
a put.

| Servers | Storage | Clients | Requests/s | p50 ms | p95 ms | p99 ms | Max ms |
|---|---|---|---|---|---|---|---|
| 3 | mem | 1 | 17,324 | 0.06 | 0.06 | 0.16 | 1.32 |
| 3 | mem | 4 | 49,127 | 0.07 | 0.12 | 0.33 | 0.68 |
| 3 | mem | 16 | 67,114 | 0.20 | 0.46 | 0.53 | 0.95 |
| 3 | mem | 64 | 58,167 | 1.09 | 1.54 | 1.76 | 2.23 |
| 3 | mem | 256 | 15,499 | 16.9 | 21.6 | 22.2 | 23.6 |
| 5 | mem | 1 | 14,654 | 0.07 | 0.08 | 0.25 | 0.68 |
| 5 | mem | 4 | 36,233 | 0.09 | 0.25 | 0.38 | 0.88 |
| 5 | mem | 16 | 44,774 | 0.32 | 0.59 | 0.68 | 1.07 |
| 5 | mem | 64 | 36,158 | 1.77 | 2.53 | 2.73 | 3.35 |
| 5 | mem | 256 | 10,630 | 24.6 | 30.4 | 32.7 | 35.8 |
| 3 | dets | 1 | 338 | 2.23 | 7.58 | 15.7 | 67.1 |
| 3 | dets | 4 | 506 | 6.54 | 15.5 | 24.6 | 154.5 |
| 3 | dets | 16 | 479 | 26.2 | 64.6 | 79.3 | 177.1 |
| 3 | dets | 64 | 512 | 105.4 | 219.3 | 246.0 | 269.4 |
| 3 | dets | 256 | 499 | 437.9 | 713.5 | 888.1 | 983.0 |
| 5 | dets | 1 | 257 | 2.61 | 11.2 | 23.1 | 116.2 |
| 5 | dets | 4 | 384 | 7.51 | 23.7 | 45.9 | 271.1 |
| 5 | dets | 16 | 301 | 40.1 | 97.2 | 114.7 | 281.8 |
| 5 | dets | 64 | 313 | 192.6 | 333.4 | 350.8 | 407.2 |
| 5 | dets | 256 | 336 | 673.7 | 1148.4 | 1388.2 | 1535.0 |

No request failed in any load run.

### Value size

Source: [results/value_size.txt](results/value_size.txt). 3 servers, 16
clients. Every request is a put.

| Storage | Value bytes | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | 100 | 67,506 | 0.20 | 0.53 |
| mem | 1,000 | 57,267 | 0.26 | 0.55 |
| mem | 10,000 | 46,359 | 0.32 | 0.67 |
| mem | 100,000 | 24,175 | 0.64 | 1.20 |
| dets | 100 | 499 | 24.5 | 115.5 |
| dets | 1,000 | 312 | 36.1 | 312.8 |
| dets | 10,000 | 219 | 55.8 | 288.1 |
| dets | 100,000 | 171 | 74.1 | 281.2 |

### Proposing to a phase-two quorum

Source: [results/propose_to.txt](results/propose_to.txt). 5 servers, 16
clients. Every request is a put.

| Storage | Quorum system | `propose_to` | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|---|
| mem | `majority` | `all` | 44,578 | 0.33 | 0.68 |
| mem | `majority` | `quorum` | 58,134 | 0.21 | 0.63 |
| mem | `{counting, 4, 2}` | `all` | 46,395 | 0.31 | 0.67 |
| mem | `{counting, 4, 2}` | `quorum` | 80,792 | 0.15 | 0.53 |
| dets | `majority` | `all` | 281 | 46.7 | 149.2 |
| dets | `majority` | `quorum` | 437 | 29.8 | 102.6 |
| dets | `{counting, 4, 2}` | `all` | 259 | 47.7 | 141.7 |
| dets | `{counting, 4, 2}` | `quorum` | 584 | 18.5 | 86.1 |

With `propose_to => quorum`, throughput is 30% to 55% higher with
`majority` and 74% to 125% higher with `{counting, 4, 2}`.

### Reads

Source: [results/reads.txt](results/reads.txt). 3 servers, 16 clients.

| Storage | Read | Requests/s | p50 ms | p99 ms |
|---|---|---|---|---|
| mem | `peace_kv:get`, a proposed value | 88,078 | 0.18 | 0.27 |
| mem | `consistent_query`, no lease | 82,128 | 0.19 | 0.28 |
| mem | `consistent_query`, `read_lease_ms => 1000` | 184,534 | 0.08 | 0.14 |
| mem | `local_query` | 183,501 | 0.08 | 0.15 |
| dets | `peace_kv:get`, a proposed value | 545 | 23.0 | 100.6 |
| dets | `consistent_query`, no lease | 635 | 22.4 | 51.4 |
| dets | `consistent_query`, `read_lease_ms => 1000` | 188,841 | 0.08 | 0.14 |
| dets | `local_query` | 189,645 | 0.08 | 0.14 |

A `consistent_query` under a read lease costs the same as a `local_query`.
Without a lease, a `consistent_query` costs the same as a write.

### Leader failure

Source: [results/recovery.txt](results/recovery.txt). dets storage. The
harness kills the node of the leader. The result is the time from the kill
to the first answered put that was sent after the kill. Each row has 10
trials.

| Servers | Election timeout ms | Min ms | Median ms | Max ms |
|---|---|---|---|---|
| 3 | 1000 | 1276.3 | 1682.6 | 1894.4 |
| 3 | 100 | 107.0 | 169.9 | 187.9 |
| 5 | 1000 | 1176.8 | 1497.9 | 1838.0 |
| 5 | 100 | 141.8 | 165.7 | 189.2 |

Every trial is between 1 and 2 election timeouts. A follower starts an
election between T and 2T after the last message from the leader, where T
is the election timeout.

### Restart from a snapshot

Source: [results/recovery.txt](results/recovery.txt). 3 servers, dets
storage, `snapshot_interval => 64`. The harness loads the machine state
with 64 kB values, kills the node of a follower, starts the node again and
starts the server. No value is proposed while the follower is down.

| Machine state | Log entries above the snapshot | Server start ms | Caught up ms | dets file MB |
|---|---|---|---|---|
| 1 MB | 18 | 8.84 | 9.57 | 2.1 |
| 10 MB | 34 | 11.0 | 11.7 | 23.9 |
| 100 MB | 58 | 25.7 | 26.7 | 224.4 |

"Server start" is the time for `peace:start_server/1` to return. The server
has then read its dets file and applied its log. "Caught up" is the time
until the commit index of the follower equals the commit index of the
leader. Both times start when `peace:start_server/1` is called. The time to
start the Erlang node is not included.

### Catch-up

Source: [results/catch_up.txt](results/catch_up.txt). 3 servers, dets
storage, 1000-byte values. The harness kills the node of a follower,
proposes a number of values, and restarts the follower. No value is
proposed while the follower catches up. The result is the time from
`peace:start_server/1` until the commit index of the follower equals the
commit index of the leader.

| Heartbeat ms | Values missed | Transferred as | Caught up ms |
|---|---|---|---|
| 200 | 100 | log entries | 451.8 |
| 200 | 1,000 | log entries | 3223.1 |
| 200 | 3,000 | log entries | 9503.3 |
| 200 | 10,000 | snapshot | 265.9 |
| 20 | 100 | log entries | 35.0 |
| 20 | 1,000 | log entries | 323.1 |
| 20 | 3,000 | log entries | 992.4 |
| 20 | 10,000 | snapshot | 26.0 |

With 10,000 missed values the leader has taken a snapshot and deleted the
log entries, so the leader sends its machine state.

## Bottlenecks

1. **Storage: one synced write per event.** With dets, throughput is about
   500 requests/s with 3 servers and about 300 requests/s with 5 servers.
   Throughput does not increase with the number of clients, and latency
   increases in proportion to the number of clients. `peace_server` performs
   one storage write for each event that it handles, and
   `peace_storage_dets` syncs the file on every write. The mem backend is
   over 100 times faster. Group commit removes this limit. Group commit is
   planned in milestone 2.
2. **Throughput falls when many values are undecided.** With mem and 3
   servers, throughput is 67,114 requests/s with 16 clients and 15,499
   requests/s with 256 clients. A probable cause is `settle/1` in
   `peace_core`. The leader calls `settle/1` for each value and for each
   `accept` message. `settle/1` sorts every undecided index and tests each
   for a quorum, so the cost of one event grows with the number of
   undecided indexes. This cause was found by reading the code. It was not
   confirmed with a profiler.
3. **One `propose` message per value.** The leader sends one message to each
   acceptor for each value. The leader does not combine values that arrive
   together. This raises the cost of bottlenecks 1 and 2. Batching is
   planned in milestone 4.
4. **Catch-up from the log is limited by the heartbeat.** A follower
   requests missing entries only when it receives a `propose` message. One
   request returns at most 64 entries. On an idle cluster the follower
   therefore receives 64 entries per heartbeat interval: 320 entries/s with
   the default heartbeat of 200 ms. 3000 missed values take 9.5 s. A
   snapshot of 10,000 values takes 0.27 s. A follower that requests the next
   batch when a batch arrives would remove this limit.
5. **Leader failure is detected only by the election timeout.** The time
   without a leader is between 1 and 2 election timeouts. A lower election
   timeout shortens the time in proportion.

No bottleneck was found in restart from a snapshot at the sizes tested.

## Limitations

- All nodes run on one machine. The results contain no network latency and
  no network bandwidth limit. The servers, the clients and the disk share
  10 cores and one disk.
- The dets results depend on the cost of a sync on this disk. The cost was
  not measured separately. The results do not transfer to another disk.
- Each configuration was run once. The variance between runs was not
  measured.
- The clients are closed-loop. A closed-loop client sends no request while
  it waits, so the latency figures understate the latency that an open
  workload with the same request rate would observe.
- The restart test reads a dets file that the operating system has in its
  page cache. A restart after a reboot of the machine reads the file from
  disk and takes longer.
- The largest machine state tested is 100 MB. The largest value tested is
  100 kB.
- The leader failure test kills the node. The other nodes observe a closed
  connection. A network partition and a paused process were not tested.
- Membership change under load was not measured.
