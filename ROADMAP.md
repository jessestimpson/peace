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
| Testing on real nodes | Not done. All fault testing is simulated. |
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

- The simulated disk is `eta_disk`, on the `simulated-disk` branch of eta.
  `make dst` needs that branch until it is merged.
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

- [ ] Export client histories from the deterministic simulation and check
      them with [Porcupine](https://github.com/anishathalye/porcupine). This
      checks the simulation's own linearizability check.
- [ ] Write a [Jepsen](https://github.com/jepsen-io/jepsen) test for the
      key-value state machine. Use the Jepsen test in
      [ra-kv-store](https://github.com/rabbitmq/ra-kv-store) as the starting
      point.
- [ ] Cover network partitions, process kills, process pauses and clock
      skew.
- [ ] Cover membership change during faults.
- [ ] Run a soak test of at least 24 hours.

Done when: the Jepsen test passes for every quorum system in
[README.md](README.md), "Quorum systems", and the soak test completes
without a violation.

### Milestone 4: Throughput and large state

Goal: remove the known structural limits on throughput and state size. The
scope depends on the results of milestone 1.

- [ ] Batch proposals: one message and one storage write for several values.
- [ ] Remove the scan of every undecided index from `settle/1` in
      `peace_core`. With the in-memory backend and 3 servers, throughput
      falls from 63,143 requests/s with 16 clients to 11,300 requests/s with
      256 clients. Group commit made this worse with 64 clients. Confirm the
      cause with a profiler first.
- [ ] Make a follower request the next batch of missing entries when a batch
      arrives. A follower currently receives 64 entries per heartbeat on an
      idle cluster.
- [ ] Allow a client to have more than one value in flight.
- [ ] Add backpressure. Bound the leader's queue of pending proposals and
      reject or delay proposals when it is full.
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
