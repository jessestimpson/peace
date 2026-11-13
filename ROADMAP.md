# Roadmap

This document lists the work required before peace can be used in
production, and the work planned after that.

## Current status

peace is at version 0.1.0. It is not ready for production use.

| Area | Status |
|---|---|
| Protocol logic | Implemented. Verified by model checking, an inductive invariant, deterministic simulation and trace validation. See [README.md](README.md), "Verification". |
| Storage | The default backend is a write-ahead log with checksums and group commit. It is tested with fault injection and in the simulation. |
| Performance | Measured on one machine. See [bench/README.md](bench/README.md). |
| Testing on real nodes | A Jepsen test on Docker nodes on one machine. See [jepsen/README.md](jepsen/README.md). A soak test has not been run. |
| Operations | Minimal. No telemetry, no leader transfer, no upgrade path. |
| Packaging | No CI and no published package. |

## Milestones

The milestones are in the order they should be done. Milestones 1 to 3
determine whether the design works outside the simulator. Later milestones
should not start before they are complete.

### Milestone 1: Benchmark

Goal: measure the current implementation, so that later work is based on
numbers.

- [x] Write a key-value state machine for benchmarking and testing.
- [x] Measure throughput and latency for 3 and 5 servers on separate Erlang
      nodes, with each storage backend.
- [x] Measure recovery time: leader election after a leader failure, restart
      from a snapshot, and catch-up of a follower that is behind.
- [x] Measure the effect of `propose_to => quorum` and of read leases.
- [x] Record the results and the method in the repository.
- [ ] Repeat the benchmark with each node on a separate machine.

Done when: the results are published in the repository and the bottlenecks
are identified.

Status: done on one machine on 2026-11-12. The results and the bottlenecks
are in [bench/README.md](bench/README.md). The nodes shared one machine, so
the results contain no network latency.

### Milestone 2: Durable storage

Goal: a storage backend that is safe and fast enough to be the default.

- [x] Implement a write-ahead log backend with group commit.
      `peace_storage_wal` is the backend. `peace_server` performs one
      storage write for each group of waiting events.
- [x] Add a checksum to every record. Detect torn and corrupt records on
      open.
- [x] Define the behaviour for a failed write or sync. The server stops
      before it sends a message that depends on the write, and is not
      restarted.
- [x] Add fault injection for the storage backend: failed sync, short write,
      corrupted record, full disk.
- [x] Run the new backend in the deterministic simulation, on a simulated
      disk that loses unsynced data when a node is killed.
- [x] Make a durable backend the default.
- [x] Repeat the benchmark from milestone 1.

Status: done on 2026-11-12. The results are in
[bench/README.md](bench/README.md).

Remaining limitations:

- The simulation does not make storage operations fail. Those faults are
  covered by unit tests.
- A checkpoint rewrites the whole machine state. See milestone 4.
- The log is shortened only by a snapshot. With
  `snapshot_interval => infinity` the log grows without limit.
- There is no procedure for a member whose storage failed. See the recovery
  item in milestone 5.

### Milestone 3: Validation on real nodes

Goal: check linearizability with tools that are independent of peace, on
separate Erlang nodes with real faults.

- [x] Export client histories from the deterministic simulation and check
      them with [Porcupine](https://github.com/anishathalye/porcupine). This
      checks the simulation's own linearizability check. Done on
      2026-11-12: `make porcupine` checks 160 runs and 8,042 operations, and
      rejects three planted bugs.
- [x] Write a [Jepsen](https://github.com/jepsen-io/jepsen) test for the
      key-value state machine. Done on 2026-11-12. See
      [jepsen/README.md](jepsen/README.md). The test was written for peace
      and does not reuse the code of
      [ra-kv-store](https://github.com/rabbitmq/ra-kv-store).
- [x] Cover network partitions, process kills and process pauses. Done on
      2026-11-12 for `majority`, `{counting, 4, 2}`, `{counting, 2, 4}` and
      a two-by-two grid. Each run lasted 180 seconds and was linearizable.
- [x] Cover clock skew. Done on 2026-11-12: a run of 300 seconds with read
      leases, wall clock skew from libfaketime and clock rates within 8%
      was linearizable. peace reads only the monotonic clock, which
      libfaketime does not change in the Erlang emulator, so the clock rate
      is changed with the `test_clock_rate` option of a server.
- [ ] Change the monotonic clock of a node from outside peace. This needs
      separate virtual machines.
- [x] Cover membership change during faults. Done on 2026-11-12 with
      majority quorums: one run of 300 seconds, linearizable.
- [x] Cover membership change with a counting or grid quorum system. Done
      on 2026-11-12: three runs with the `quorums` fault were linearizable,
      with 8 confirmed changes among majority, counting, grid and weighted
      quorum systems.
- [x] Cover a custom quorum module. Done on 2026-11-12 with a weighted
      voting module: one run of 180 seconds, linearizable.
- [ ] Run a soak test of at least 24 hours. `jepsen/soak.sh 24` runs it. It
      has not been run.

Done when: the Jepsen test passes for every quorum system in
[README.md](README.md), "Quorum systems", and the soak test completes
without a violation.

### Milestone 4: Throughput and large state

Goal: remove the known structural limits on throughput and state size. The
scope depends on the results of milestone 1.

- [x] Batch proposals: one message and one storage write for several
      values. Done on 2026-11-12. `peace_server` combines the `propose`
      messages and the `accept` messages of a group of events.
- [x] Remove the scan of every undecided index from `settle/1` in
      `peace_core`. Done on 2026-11-12. The merge of storage batches in
      `peace_server` was also quadratic and is now linear. With the
      in-memory backend, 3 servers and 256 clients, throughput rose from
      11,300 to 121,385 requests/s. The cause was found by reading the code
      and confirmed by the measurement. No profiler was used.
- [x] Make a follower request the next batch of missing entries when a batch
      arrives. Done on 2026-11-12. Catch-up of 3,000 values takes 353 ms
      instead of 9,489 ms with a heartbeat of 200 ms.
- [x] Reduce the number of syncs that a client waits for. Done on
      2026-11-12. A leader sends its proposals before its own write, a
      write of only `learned` entries is not synced, and a leader answers a
      client before a write that the answer does not depend on. With the
      write-ahead log and 1 client, the median latency fell from 0.49 ms to
      0.35 ms.
- [x] Move storage writes to a process that is separate from the server
      process, so that a leader handles `accept` messages while it syncs.
      Done on 2026-11-12, with `peace_writer`. With the write-ahead log and
      16 clients, the median latency fell from 1.29 ms to 0.92 ms. With the
      in-memory backend and 256 clients, throughput fell by 11%.
- [ ] Investigate the tail latency with the write-ahead log. The maximum
      latency is up to 318 ms. A probable cause is the checkpoint that is
      written for each snapshot.
- [ ] Investigate the throughput of 5 servers with the write-ahead log. It
      is 9,929 requests/s with 64 clients. 3 servers get 25,249.
- [ ] Allow a client to have more than one value in flight.
- [ ] Add backpressure. Bound the leader's queue of pending proposals and
      the writes that wait in the mailbox of the storage process, and
      reject or delay proposals when a bound is reached.
- [ ] Transfer and store snapshots in chunks. A snapshot is currently one
      term in one message, which blocks the distribution channel while it is
      sent.
- [ ] Evaluate a transport that is separate from Erlang distribution for
      large messages.

Done when: the benchmark shows the target throughput, and a snapshot larger
than available memory headroom can be transferred without delaying
heartbeats. The throughput target is to be set after milestone 1.

### Milestone 5: Operations

Goal: an operator can run, observe, maintain and upgrade a cluster.

- [ ] Emit `telemetry` events for elections, role changes, commit index,
      replication lag, snapshot activity and storage latency.
- [ ] Log role changes and errors through `logger`.
- [ ] Add a non-voting stage for a joining server. A server currently counts
      toward quorums before it has caught up, which can delay commits.
- [ ] Add leader transfer, for use before a node is stopped.
- [ ] Add a documented procedure and an API to recover a cluster that has
      permanently lost a phase-one quorum.
- [ ] Add a version field to messages, stored entries and snapshots.
- [ ] Add state machine versioning, so that the machine code can be upgraded
      on a running cluster.
- [ ] Add session expiry by time. Define what a client observes when its
      session is evicted.
- [ ] Write an operations guide: deployment, sizing, monitoring, membership
      change, upgrade and recovery.

Done when: a rolling upgrade between two versions with different message
formats passes in the simulation and in the Jepsen test.

### Milestone 6: Release

Goal: a published, versioned package.

- [ ] Set up CI for `make test`, `make dst`, `make trace` and `make tlc`.
- [ ] Run `make ind` and `make tlc-long` in CI on a schedule or when the
      models change.
- [ ] Pin the eta dependency to a released version.
- [ ] Generate API documentation.
- [ ] Add a changelog and a compatibility policy for the API, the message
      format and the storage format.
- [ ] Publish to Hex.

Done when: version 1.0.0 is published.

## Verification work

This work improves confidence in the existing implementation. It does not
block the milestones above and can be done at any time.

- [ ] Extend trace validation to writes that are in progress. A server
      with a tracer waits for every write, because the TLA+ model has no
      state for an entry that a server holds in memory and has not stored.
      The model needs a separate action for "the acceptance is stored".
- [ ] Add trace validation for the membership model, `Reconfig.tla`.
- [ ] Add an inductive invariant for the membership model.
- [ ] Model read leases. They are currently covered only by simulation and
      unit tests.
- [ ] Include in each trace the messages a server has received, so that
      trace validation can require that an action is justified by received
      messages and not only by sent messages.
- [ ] Prove the inductive invariant for all cluster sizes with TLAPS. The
      Apalache check uses fixed constants.

## Protocol extensions

These parts of the thesis
([docs/UCAM-CL-TR-935.pdf](docs/UCAM-CL-TR-935.pdf)) are not implemented.
None is required for production use.

| Extension | Thesis | Effect |
|---|---|---|
| Revision B | §4.2 | Quorums can differ between epochs. Membership change in peace is related but does not implement it. |
| Revision C | Chapter 5 | A proposer can complete phase one before it has a full phase-one quorum. |
| Quorum-based value selection | Chapter 6 | A proposer has more freedom in the value it proposes after phase one. |
| Other epoch allocation schemes | Chapter 7 | A proposer can decide a value in one round trip without a leader. This generalises Fast Paxos. |

## Not planned

- A general-purpose key-value store. The key-value state machine in
  milestone 1 is for benchmarking and testing.
- Byzantine fault tolerance. peace tolerates crash faults and message
  faults.

## Memory nodes

This work is not scheduled. It does not block the milestones above.

Goal: support a state machine whose state is valid only while the nodes
run. The example is a process registry, where the state contains Erlang
pids. Such state must not be read back from disk after a node restarts.

Design: a memory node keeps its acceptor state, its log and its snapshot in
an ETS table and writes nothing to disk. The peace supervisor owns the
table.

| Event | Table | Server id |
|---|---|---|
| The server process restarts | The table is kept. | The server keeps its id and recovers its promise and its accepted proposals. |
| The node restarts, or the peace application restarts | The table is lost. | The server gets a new incarnation and joins through a membership change. |

A server that loses its acceptor state must not answer under its old id. A
new incarnation is a new acceptor that has promised nothing.

- [ ] Check what the thesis
      ([docs/UCAM-CL-TR-935.pdf](docs/UCAM-CL-TR-935.pdf)) assumes about
      stable storage, and state in the documentation where memory nodes
      depart from it.
- [ ] Add an ETS storage backend. The supervisor creates one public
      `ordered_set` table in `init/1`. The key is `{ServerName, Key}`. A
      group of events is written with one `ets:insert/2` call, which is
      atomic.
- [ ] Add an incarnation to the server id. The incarnation is created with
      the table and stored in the table. Every message carries the
      incarnation of the sender and of the destination. A server drops a
      message for another incarnation.
- [ ] Define how a new incarnation replaces the old incarnation in a grid
      quorum system, where the rows list server ids.
- [ ] Replace on start: a new incarnation starts as a non-member, asks the
      leader to replace the old incarnation of the same node, and catches
      up from a snapshot. Several nodes can restart at the same time, and
      only one membership change runs at a time.
- [ ] Refuse to start a memory server that has no state in the table under
      an id that is a member.
- [ ] Add monitor effects for the machine, as in ra:
      `{monitor, process, Pid}` and `{monitor, node, Node}`. The leader
      performs them and issues them again from `state_enter/2`. The down
      signal is proposed as a value, so that every replica removes the pid.
- [ ] Define a bootstrap rule for a cluster that can no longer form a
      quorum of live incarnations. A proposed rule: a fixed node list, a
      cluster incarnation, and a new cluster forms only when a majority of
      the listed nodes are new incarnations that know of no live cluster.
      Add the rule to the TLA+ model before the implementation.
- [ ] Add an event that tells the application that the state was reset. A
      server that survives from the old cluster discards its state and
      joins the new cluster.
- [ ] Add a simulation workload with memory nodes, kills and replace on
      start. Add a planted bug in which a node rejoins under its old
      incarnation.
- [ ] Add a process registry as an example machine.

Limitations of the design:

- A node restart is a permanent failure of one acceptor. If the stopped
  nodes include a member of every phase-one quorum or of every phase-two
  quorum, the cluster cannot decide again and the state is lost.
- The log and the snapshot are copies outside the server process, so the
  machine state is held in memory twice.
- A value that makes `apply/3` crash on every server also crashes every new
  incarnation.

Done when: the process registry passes the simulation workload and a Jepsen
run with kills, and the bootstrap rule is model checked.
