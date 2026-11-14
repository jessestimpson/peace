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
- There is no procedure for a member whose storage failed. See the
  replacement rule in "Memory nodes", which also applies to disk servers,
  and the forced recovery item in milestone 5.

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
      16 clients, the median latency fell from 1.29 ms to 0.91 ms. With the
      in-memory backend and 256 clients, throughput fell by 9%.
- [x] Investigate the tail latency with the write-ahead log. Done on
      2026-11-12. The disk of the benchmark machine stops for 50 ms to
      300 ms a few times in 10 seconds, and every node shares that disk.
      The cause of the stops is not known. The checkpoint is not the cause.
      See [bench/README.md](bench/README.md), "One shared disk".
- [x] Investigate the throughput of 5 servers with the write-ahead log. Done
      on 2026-11-12. The disk performs a fixed number of syncs per second
      in total, so 5 servers on one disk get fewer syncs each than 3
      servers.
- [x] Keep latency low when one server has a slow disk. Done on 2026-11-12.
      The storage process merges every write that waits, and a server does
      not wait for the write of a snapshot. With a sync that is 20 ms slower
      on the leader, 16 clients get 18,378 requests/s with a maximum latency
      of 24.7 ms. See [bench/README.md](bench/README.md), "One slow disk".
- [ ] Repeat the benchmark with each server on its own disk, or on its own
      machine. The benchmark on one disk cannot measure the throughput of
      5 servers or the tail latency.
- [x] Take snapshots at different indexes on different servers. Done on
      2026-11-13. A server takes its snapshot at an offset that is a hash
      of the server id. The effect on latency with a large machine state
      was not measured.
- [x] Allow a client to have more than one value in flight. Done on
      2026-11-13. The values of a session are applied in the order of
      their sequence numbers, and the servers keep the last
      `session_window` replies of a session. `peace_session` is a client
      process with up to `window` values undecided. The throughput of
      100 to 1,600 session processes together was measured on 2026-11-14.
      See "Overload" in bench/README.md.
- [x] Add backpressure. Done on 2026-11-13. A leader that holds
      `max_pending' undecided values answers `{error, overloaded}'. The
      storage process merges every write that waits, so the writes that
      wait are bounded by the arrivals during one sync.
- [x] Bound the mailbox of a server. Done on 2026-11-14. A server that
      holds more than `max_mailbox` client requests keeps the oldest and
      refuses the newest. A session process waits a random time that
      doubles, and halves the number of values that it sends, when a leader
      answers `{error, overloaded}`.
- [ ] Lower the cost of a refusal. At 3 times the rate that a leader can
      decide, the leader spends most of its time on refusals. See
      "Overload" in bench/README.md.
- [x] Transfer and store snapshots in chunks. Done on 2026-11-13. A server
      sends a snapshot in chunks of `snapshot_chunk_bytes` bytes, and the
      receiver asks for one chunk at a time. The write-ahead log writes a
      snapshot as one record per chunk, and the storage process performs
      other writes between two chunks.
- [ ] Bound the memory that a snapshot needs. The machine state is one
      term. A server encodes the whole snapshot into one binary to send it
      or to store it, and decodes the whole binary to receive it. A bound
      needs a machine callback that produces and consumes the state in
      parts.
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
- [ ] Add member tags and leadership pinning. Each member has a set of
      tags, for example its datacenter or its region. The tags are part of
      the configuration and are changed with `change_members`. A pinning
      rule names the tags of the servers that may campaign. When a server
      with a pinned tag is reachable, a server without the tag does not
      campaign, and a leader without the tag transfers leadership to a
      server with the tag. Example: under `{counting, 4, 2}` with two
      servers on each coast and one in the centre, a pin to `east` keeps
      the leader and its phase-two quorum on the east coast.
- [ ] Add operator-driven forced recovery for a cluster that has
      permanently lost a phase-one quorum. Example: under
      `{counting, 4, 2}` over five servers, both servers on one coast fail
      while the leader is on that coast. The 3 remaining servers cannot
      elect a leader, so `change_members` cannot run. The operator names
      the surviving servers and a new quorum system, and the surviving
      servers adopt that configuration without a phase-one quorum of the
      old configuration. The procedure accepts these consequences:
  - Data loss. A value that was decided only by the lost servers is not on
    any surviving server, although a client received an acknowledgement.
  - Split brain. A lost server that returns with the old configuration can
    form quorums of the old configuration and decide different values. The
    procedure must state that the operator has to destroy or fence the lost
    servers. The recovered cluster should have a new cluster identity, and
    servers should reject messages that carry the old identity.
  - The API and the documentation must name both consequences. The
    recovery must be logged.
- [ ] Add a version field to messages, stored entries and snapshots.
- [ ] Add state machine versioning, so that the machine code can be upgraded
      on a running cluster.
- [ ] Add session expiry by time. A client of an evicted session is
      answered `{error, {session_gap, 0}}`, and `peace_session` answers
      `{error, session_evicted}`. A copy of the first value of an evicted
      session can still be applied again.
- [ ] Let a session continue after its session process restarts.
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

Member identity: a member is identified by `{Node, Incarnation}`. The
incarnation is created when the storage is created, and is stored in the
storage. The incarnation therefore changes exactly when the acceptor state
is lost.

| Storage | When the incarnation is created | Value |
|---|---|---|
| ETS table | When the supervisor creates the table | `make_ref()` |
| Disk | When the data directory is initialised | A unique value written to the data directory |

The Erlang node `creation` value is not used as the incarnation. The
creation value changes when the node restarts, which does not match the
lifetime of the acceptor state:

| Event | Creation changes | Acceptor state lost |
|---|---|---|
| The node restarts, memory node | yes | yes |
| The peace application restarts and the node keeps running, memory node | no | yes |
| The node restarts, disk node | yes | no |

In the second row, an identity based on creation would let a server answer
under its old identity without its promises. That is unsafe. In the third
row, the server would be replaced although its state is still valid. A
reference from `make_ref()` contains the creation value of the node, so it
also changes when the node restarts.

Replacement rule: when a server joins with the same node as a member and a
different incarnation, the leader replaces the old member with the new
server. The new server is not added as an extra member. The replacement
takes the place of the old member in the configuration: its row and column
in a grid quorum system, its weight in a weighted quorum system, and its
tags.

Detection of a lost table: a `persistent_term` key records that a memory
server created its table during the current lifetime of the node. A
`persistent_term` key belongs to no process. It lasts until the node stops
or until code erases it, so it survives a restart of the peace application.
The server writes the key once, when it creates the table, so the global
garbage collection that an update of a `persistent_term` causes happens
once per table.

| Key | Table | Meaning |
|---|---|---|
| absent | absent | First start of the server during this lifetime of the node. |
| present | present | The server process restarted. The state is valid. |
| present | absent | The table was lost while the node kept running. |

In the third row, the server reports the loss, for example through
`logger` and `telemetry`. The server then starts with a new incarnation
and replaces its old member.

Alternative considered: use the Erlang node `creation` value as the
incarnation, so that the identity is `{Node, Creation}`. In the third row
of the table above, the server would refuse to start, and the operator
would restart the node. The loss of the state would then happen only
together with a node restart.

Advantages of identity based on creation:

- Other nodes can learn the incarnation of a member from any pid on its
  node, or when the node connects again. The leader does not need a join
  request from the new incarnation.
- A pid contains the creation value of its node, and the runtime drops a
  message sent to a pid of an earlier creation. If servers sent peer
  messages to pids, the runtime would drop a message addressed to the old
  incarnation.
- The rule for operators is that a restarted node is a new member.

Disadvantages, which are the reasons it was not chosen:

- A disk server must not use creation, because its state survives a node
  restart. Disk servers would still need an incarnation stored in the data
  directory, so peace would have two identity schemes.
- Safety depends on a new creation value at each start of the node. Since
  OTP 23 the value has 32 bits and EPMD assigns it at registration. A
  custom EPMD module, or a setup without EPMD, can return the same value
  every time. Two lifetimes of a node would then share one identity.
- A restart of the peace application that loses the table needs a node
  restart. The design above replaces the member without operator action.
- The pid of a server changes when the server process restarts, and the
  state does not change. Peers would have to learn the new pid. The
  explicit incarnation checks on messages would still be needed for this
  case and for the sender check.
- Safety would depend on the `persistent_term` key. Code that erases the
  key, or an upgrade that changes the key, would allow a server to answer
  under its old identity without its state. In the design above, the key
  only affects reporting.

- [ ] Check what the thesis
      ([docs/UCAM-CL-TR-935.pdf](docs/UCAM-CL-TR-935.pdf)) assumes about
      stable storage, and state in the documentation where memory nodes
      depart from it.
- [ ] Add an ETS storage backend. The supervisor creates one public
      `ordered_set` table in `init/1`. The key is `{ServerName, Key}`. A
      group of events is written with one `ets:insert/2` call, which is
      atomic.
- [ ] Identify a member by `{Node, Incarnation}`, with the incarnation
      created with the storage, for the ETS backend and for the disk
      backends. Every message carries the incarnation of the sender and of
      the destination. A server drops a message for another incarnation.
- [ ] Add a configuration operation that replaces one member with another
      and keeps the position of the old member: grid row and column,
      weight and tags. The operation is a membership change through the
      joint configuration.
- [ ] Replace on start: a new incarnation starts as a non-member, asks the
      leader to replace the member with the same node and a different
      incarnation, and catches up from a snapshot. Several nodes can
      restart at the same time, and only one membership change runs at a
      time. The leader either queues the replacements or combines them
      into one change.
- [ ] Use the replace path for a disk server whose data directory was lost
      or wiped. The server initialises a new data directory, gets a new
      incarnation, and replaces its old member. This removes the
      milestone 2 limitation for a member whose storage failed.
- [ ] Add to the TLA+ membership model a replacement in which the old
      acceptor has lost its state, and check that a lost incarnation that
      cannot answer does not break safety.
- [ ] Refuse to start a memory server that has no state in the table under
      an id that is a member.
- [ ] Add the `persistent_term` key that detects a table lost while the
      node kept running. Report the loss through `logger` and `telemetry`.
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
