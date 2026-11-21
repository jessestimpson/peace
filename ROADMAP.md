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
| Testing on real nodes | A Jepsen test on Docker nodes on one machine. See [jepsen/README.md](jepsen/README.md). A soak test of 24 hours ran on 2026-11-20 without a violation. |
| Operations | Minimal. No telemetry and no leader transfer. Messages and stored data have a version. Servers with a common message version run in one cluster, so a cluster can be upgraded one server at a time. The procedure is tested in the simulation with test versions and not in the Jepsen test. |
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
- A member whose storage failed is replaced with
  `peace:replace_member/3`. See "Member identity". A cluster that has lost
  a phase-one quorum has no procedure. See the forced recovery item in
  milestone 5.

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
- [x] Run a soak test of at least 24 hours. Done on 2026-11-20:
      `jepsen/soak.sh 24` ran 135 runs of 600 seconds without a violation.
      Knossos ran out of memory in 54 runs. `jepsen/recheck.sh` checked
      all 9,070 keys again with Porcupine, and all are linearizable. See
      [jepsen/README.md](jepsen/README.md), "Soak test".

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
      - [x] Remove the mailbox scan in `drain/2`. Done on 2026-11-21.
            `drain/2` adds each client request that it reads to the
            backlog, or refuses the request. At 300,000 puts sent per
            second the leader applied 34,229 puts per second, against
            13,461 before.
      - [ ] Reduce the work of one refusal in the server process. After
            the change above, the refusals take about 24% of the traced
            CPU time of the leader at 300,000 puts sent per second.
      - Not planned: a refusal in the calling process, and a separate
        process that receives the requests of remote callers.
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
- [x] Add a version field to messages, stored entries and snapshots. Done
      on 2026-11-19. Every message between servers names a version in its
      envelope. All stored data of a server has one format, which is
      stored with the identity of the server. Both numbers are 1. A server
      drops a message of another version and does not start on data of a
      later format. See "Versions" in `peace_server`.
- [x] Agree on the message version in a cluster. Done on 2026-11-19.
      A server handles a range of message versions and names the range in
      every envelope. A sender uses the latest version that the sender and
      the receiver both handle. The agreement is between each pair of
      servers and is not stored. See `peace_wire`, and "Upgrading a
      running cluster" in [README.md](README.md). The simulation upgrades
      a cluster through three ranges of test versions, with rollbacks.
- [ ] Add a rolling upgrade to the Jepsen test: two builds of the node
      with different ranges of message versions.
- [ ] Add a cluster-wide feature level for a change of behaviour that
      every member must make at the same time. The choice of a message
      version covers the encoding of a message only.
- [x] Give a founder that has not stored the configuration that forms the
      cluster a way to obtain it. Done on 2026-11-19. The upgrade workload
      of the simulation found the fault in seed 72: a founder was killed
      before the write of the configuration returned, received entries
      from the leader after its restart, and held no members at commit
      index 107. Such a server now asks its leader for the configuration.
      See "A founder without a configuration" in `peace_core`. The
      exchange is not in a TLA+ model.
- [ ] Give the requests of a client a version. They are `gen_server` calls
      and casts without one.
- [ ] Add state machine versioning, so that the machine code can be upgraded
      on a running cluster.
- [ ] Add session expiry by time. A client of an evicted session is
      answered `{error, {session_gap, 0}}`, and `peace_session` answers
      `{error, session_evicted}`. A copy of the first value of an evicted
      session can still be applied again.
- [ ] Let a session continue after its session process restarts.
- [ ] Write an operations guide: deployment, sizing, monitoring, membership
      change, upgrade and recovery.

The following items change membership, elections and recovery. The items
are done in this order:

1. Member identity.
2. The non-voting stage and leader transfer.
3. Forced recovery.
4. Member tags and leadership pinning.

Reasons for the order:

- Forced recovery uses the identity checks on messages that member identity
  adds.
- A replacement of a member is slow without the non-voting stage, and a
  planned node stop needs leader transfer.
- Leadership pinning needs leader transfer.
- Leadership pinning is after forced recovery because a pin makes the loss
  of a phase-one quorum more likely to lose decided values.

- [x] Do the work in "Member identity". The work identifies a member by the
      incarnation of its storage, separates the formation of a cluster from
      the start of a server, and adds an operation that replaces a member.
      Done 2026-11-14.
- [ ] Add a non-voting stage for a joining server. A server currently counts
      toward quorums before it has caught up, which can delay commits. A
      replacement for a member whose storage was lost starts with no
      entries, so each replacement has this cost. A part exists since
      2026-11-16: a passive server receives decided values and takes no
      part until `peace:activate/1` is called. A passive member is still
      counted in the quorum system, and nothing activates it when it has
      caught up.
- [ ] Add leader transfer, for use before a node is stopped.
- [ ] Add operator-driven forced recovery for a cluster that has
      permanently lost a phase-one quorum. Example: under
      `{counting, 4, 2}` over five servers, both servers on one coast fail
      while the leader is on that coast. The 3 remaining servers cannot
      elect a leader, so `change_members` cannot run. The operator names
      the surviving servers and a new quorum system, and the surviving
      servers adopt that configuration without a phase-one quorum of the
      old configuration. Rules of the procedure:
  - Every named surviving server must answer before the new configuration
    is in force. A quorum of the named servers is not enough. A value that
    was decided by the lost leader and one surviving server is kept only if
    that surviving server answers.
  - The recovery chooses the entry for each index as a candidate does in
    phase one: the accepted proposal with the highest epoch among the
    answers.
  - The cluster has a cluster identity `{Generation, Token}`. A recovery
    increases the generation by 1 and takes the token from the operator.
    Every message carries the cluster identity. A server drops a message
    that carries a lower generation.
  - A server that receives a message with a higher generation, and that is
    not a member of the recovered configuration, stops serving clients and
    reports the event. Without this rule a lost leader that returns keeps
    answering clients.
  - A server adopts one recovery for a generation. A server refuses a
    second recovery that has the same generation and a different token or
    a different configuration. This rule prevents two operators from
    creating two clusters.
  - The API and the documentation must name the two consequences below.
    The recovery must be logged.

  The procedure accepts these consequences:
  - Data loss. A value that was decided only by the lost servers is not on
    any surviving server, although a client received an acknowledgement.
  - Split brain. A lost server that returns with the old configuration,
    and that cannot reach a recovered server, can form quorums of the old
    configuration and decide different values. The procedure must state
    that the operator has to destroy or fence the lost servers.
- [ ] Add a simulation test and a Jepsen test for forced recovery. The
      tests must define which acknowledged values the checker may accept as
      lost.
- [ ] Add member tags and leadership pinning. Each member has a set of
      tags, for example its datacenter or its region. A pinning rule names
      the tags of the servers that should lead. Rules:
  - The tags and the pinning rule are part of the decided configuration and
    are changed with `change_members`. Every server then uses the same
    rule.
  - A server without a pinned tag uses a longer election timeout than a
    server with a pinned tag. A server without a pinned tag is still
    allowed to campaign. A rule that forbids the campaign while a pinned
    server is reachable can leave the cluster without a leader, because a
    pinned server that is reachable is not always able to collect a
    phase-one quorum.
  - A leader without a pinned tag transfers leadership to a server with a
    pinned tag only when that server has caught up.
  - Pinning changes elections only. Pinning does not change the quorums,
    so the TLA+ safety models do not change.

  Example: under `{counting, 4, 2}` with two servers on each coast and one
  in the centre, a pin to `east` keeps the leader and its phase-two quorum
  on the east coast.

  Consequence: with that pin, the most recent decided values can be stored
  only on the two east servers. The loss of the east coast then loses
  acknowledged values and requires forced recovery. The documentation must
  state this consequence. A grid quorum system whose phase-two quorums
  contain servers from two sites avoids the consequence and has a higher
  commit latency.

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

The extension points of member identity were added on 2026-11-16 and
2026-11-17: an incarnation from the storage backend, formation with known
members, formation with a machine state, a passive server and a gate.
They are in the simulation, and passive servers and gates are in trace
validation. See "Verification" in [README.md](README.md). They are in no
TLA+ model and not in the Jepsen test.

- [ ] Add the extension points of member identity to the Jepsen test: a
      server with a gate, a passive replacement, and a fault that deletes
      a data directory.
- [ ] Add a machine state to the model, so that trace validation covers
      formation with a machine state.

This work improves confidence in the existing implementation. It does not
block the milestones above and can be done at any time.

- [ ] Reduce the time that the test suite takes. On 2026-11-21, the 38
      tests of the simulation took 3,973 seconds when they ran one after
      another in one Erlang node. After the three changes below, `make dst`
      takes 388 seconds on a machine with 4 performance cores and 6
      efficiency cores.
      - [x] Run the tests of the simulation in several Erlang nodes at the
            same time. Done on 2026-11-21 with `dst/run.sh`. The 38 tests
            took 1,000 seconds with 8 nodes.
      - [x] Remove the quadratic cost from the `linearizable_read` check
            of the harness. Done on 2026-11-21. The check computed the
            machine state after every prefix of the decided log for every
            query, after every step. The check now computes the applied
            puts once for each check. The 38 tests took 671 seconds with 8
            nodes.
      - [x] Read the state of each server once for each check. Done on
            2026-11-21. The check read each server four times. A read
            copies the whole state of the server and produces two trace
            messages for the scheduler of eta. 256 runs have the same
            traces and the same outcomes as before, and take between 30%
            and 43% less time. The 38 tests take 388 seconds with 8 nodes.
      - [ ] Do the work of the check only for a server that changed. The
            check after every step takes about 75% of the time of a run:
            with the check switched off, 20 runs with 5 servers take 2.0
            seconds, against 11.6 seconds with the check. Between two
            checks, 83% to 88% of the servers have the same state and the
            same disk. This item needs two features in eta: the process
            that ran in a step, and a check process that lives for the
            whole run. The reduction count of a server detects only 43% to
            78% of the unchanged servers. A copy of the state in an ETS
            table costs as much as the read.
      - [ ] Split the longest tests. The time of `make dst` is the time
            of the longest test: `stale_leader_is_caught_test_`, 347
            seconds while 7 other nodes run.
      - [ ] Run the tests of `make trace` and `make porcupine` in several
            Erlang nodes at the same time.
      - [ ] Add a target with a lower seed count for use during
            development. Keep the current seed counts for CI and before a
            release.
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
- Memory nodes: servers that keep their state only in memory, with a rule
  that forms a cluster again without an operator after most nodes restart
  (the bootstrap rule). An earlier version of this document planned the
  work. A TLA+ model refuted the safety argument of that plan: a node that
  promises to leave a cluster, restarts and loses the promise can be
  admitted to the cluster again. The idea is tested as a hypothesis in a
  separate repository, peace_ets. peace supports that repository only
  through the storage behaviour and `peace_storage_check`, which serve any
  backend.

## Member identity

This work is the first of the ordered items in milestone 5. It applies to
every storage backend. The work was done on 2026-11-14. The section describes the design as it was built.

Goal: a server that has lost its acceptor state never answers under the
identity that it had before the loss. The loss of the state of one server
then has the same effect as the permanent crash of one acceptor, and a
membership change repairs it.

### Identity

A member is identified by `{Name, Node, Incarnation}`. `{Name, Node}` is
the present `server_id()` and remains the address of the server.

Rules for the incarnation:

- The incarnation belongs to one server. Two servers that share a storage
  table have different incarnations.
- A server creates its incarnation when the server starts and finds no
  stored state for its name.
- The incarnation is 16 bytes from `crypto:strong_rand_bytes/1`, for every
  storage backend.
- The incarnation is stored in the storage backend of the server, with the
  acceptor state. A server stores its incarnation before it handles any
  message. A server does not start on a promise, an entry or a snapshot
  that is stored without an incarnation.
- Every message between members carries the incarnation of the sender and
  of the destination. A server drops a message for another incarnation. A
  leader counts an acknowledgement only from the incarnation that the
  configuration names.

A reference from `make_ref()` is not used as the incarnation. A reference
contains the creation value of the node, so the uniqueness of the reference
across two lifetimes of a node depends on the creation value. See the
second disadvantage in "Alternative considered". How the runtime chooses
the first reference number after a start has not been checked.

### Formation and start

A server currently takes the initial configuration from its start
arguments. This cannot continue, for two reasons:

- The initial configuration cannot name the incarnations in advance,
  because each server creates its incarnation when it starts.
- A server that restarts with the same start arguments and no stored state
  cannot be distinguished from a server that starts for the first time. The
  restarted server would answer as a member without its promises.

Formation therefore becomes an operation that is separate from start, as
`start_cluster` and `restart_server` are separate in ra:

| Operation | When it is used | Effect |
|---|---|---|
| Form a cluster (`peace:form_cluster/3`) | Once, by the operator or by the application | The operation collects the incarnation of every named server and stores the initial configuration, with the incarnations, on every named server. A server stores the configuration only if it has none. The operation stores nothing if a server does not answer or has another configuration. |
| Start a server, stored state present | Every start after a stop or a crash | The server continues under its stored identity. |
| Start a server, no stored state | A new server, or a server whose storage was lost | The server creates a new incarnation and starts as a non-member. The server does not use a configuration from its start arguments. |

### Replacement

Replacement rule: when a server asks to join with the name and the node of
a member and with a different incarnation, the leader replaces the old
member with the new server. The new server is not added as an extra member.
The replacement takes the place of the old member in the configuration: its
row and column in a grid quorum system, its weight in a weighted quorum
system, and its tags. The replacement is a membership change through the
joint configuration.

The replacement is safe under the present rule for candidates. A candidate
needs a phase-one quorum of every configuration that may have been in force
for the indexes that the candidate asks about. A candidate that has not
applied `final(New)` therefore needs a phase-one quorum of `Old`, and that
quorum contains a server that stores each decided value. A candidate that
has applied `final(New)` stores those values already.

A replacement is requested in one of two ways:

| Way | Who asks | Challenge |
|---|---|---|
| `peace:replace_member/3` | The operator. The function reads the incarnation from the server that runs. | No |
| The option `rejoin` | A server that starts without stored state. The server sends a replace request to the addresses in `rejoin` on each election timeout. | Yes |

Rules for the replace request:

- A replace request carries no destination incarnation, because a server
  without stored state does not know the incarnation of any member. The
  request names the incarnation of the sender.
- Before the leader proposes the replacement, the leader sends a challenge
  to the incarnation that the request names. The challenge holds the epoch
  of the leader. The leader proposes the replacement only after that
  incarnation answers. Reason: incarnations are not ordered. Without the
  challenge, a delayed request from a retired incarnation would replace
  the running member with a server that no longer exists.
- The leader ignores a request from an incarnation that is already a
  member.
- The leader replaces, on its next heartbeat, every member whose
  replacement has answered. The servers that answer within one heartbeat
  interval are replaced by one membership change. One change shortens the
  time during which a failure of the leader stops the cluster.
- A server without stored state does not send the replace request by
  default. The server logs a notice and waits for the operator. Reason: a
  data volume that is not mounted when the node starts looks like lost
  storage. Several nodes with the same fault would each replace their
  member and discard data that still exists.

### Availability

A replaced member is a permanent failure of one acceptor in the old
configuration.

- Under `{counting, 4, 2}` over 5 servers, the old configuration has a
  phase-one quorum while at most 1 member is lost. The loss of the storage
  of the leader and of one other server at the same time stops the cluster
  permanently, and forced recovery is then required.
- A majority quorum system over 5 servers has a phase-one quorum while at
  most 2 members are lost.
- A server that has not applied `final(New)` cannot become leader when the
  old configurations that the server needs have lost a phase-one quorum.
  That server can only catch up from the leader.
- A procedure that restarts every node in turn must wait, after each node,
  until every member has applied `final(New)`. The procedure should
  transfer leadership before it stops the node of the leader.

### Alternative considered

Use the Erlang node `creation` value as the incarnation, so that the
identity is `{Name, Node, Creation}`. The creation value changes when the
node restarts, which does not match the lifetime of the acceptor state:

| Event | Creation changes | Acceptor state lost |
|---|---|---|
| The node restarts, server with state in memory | yes | yes |
| The peace application restarts and the node keeps running, server with state in memory | no | yes |
| The node restarts, server with state on disk | yes | no |

In the second row, an identity based on creation would let a server answer
under its old identity without its promises. That is unsafe. The server
would have to detect the loss and refuse to start, and the operator would
restart the node. In the third row, the server would be replaced although
its state is still valid.

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
  restart. The chosen design replaces the member without operator action.
- The pid of a server changes when the server process restarts, and the
  state does not change. Peers would have to learn the new pid. The
  explicit incarnation checks on messages would still be needed for this
  case and for the sender check.
- Safety would depend on a separate mechanism that detects state lost
  while the node keeps running. An error in that mechanism would allow a
  server to answer under its old identity without its state. In the chosen
  design, the incarnation is stored with the state and is lost with it.

### Work

- [x] Check what the thesis
      ([docs/UCAM-CL-TR-935.pdf](docs/UCAM-CL-TR-935.pdf)) assumes about
      stable storage, and state in the documentation where the replacement
      of a member that lost its state departs from it. The thesis assumes
      a fixed set of participants whose persistent state is unchanged
      after a restart (section 1.6). Section 3.12, "Fail-stop model",
      describes a participant that does not restart, with reconfiguration
      to restore the fault tolerance. peace uses the fail-stop model for a
      server that has lost its state. See "Member identity" in
      `peace_core`.
- [x] Add the incarnation to the member identity, to the stored state of
      every backend, and to every message between members.
- [x] Add the operation that forms a cluster, `peace:form_cluster/3`, and
      remove the initial configuration from the start arguments of a
      server.
- [x] Add a configuration operation that replaces one or more members and
      keeps the position of each old member. The operation keeps the rows
      of a grid. A custom quorum module can export `replace_member/3`.
      Tags do not exist yet.
- [x] Add the replace request, the challenge and the catch-up for a server
      that starts without stored state.
- [x] Add the option `rejoin`, which lets a server send the replace request
      without the operator.
- [x] Refuse to start a server whose stored state names another node.
- [x] Add these cases to the TLA+ membership model, in
      [formal/Replace.tla](formal/Replace.tla):
  - a replacement in which the old acceptor never answers again;
  - a replace request from a retired incarnation, with and without the
    challenge;
  - an acceptor that loses its state and answers under its old identity.
    The model checker reports a safety violation for this case.
- [x] Add a simulation workload in which servers lose their storage and are
      replaced. Add two planted bugs: a server that rejoins under its old
      incarnation, and a leader that accepts a replace request without the
      challenge.
- [ ] Add a Jepsen nemesis that wipes the data directory of a node, and
      start the nodes with `rejoin`.
- [ ] Add the incarnation to trace validation. The trace model has a fixed
      set of acceptors.

### Limitations

- A data directory that is restored from a backup, or from a disk image,
  keeps its incarnation and has lost the promises made after the backup.
  The incarnation does not detect this case. The operator must wipe the
  directory and let the server be replaced.
- A replace request needs a leader. If the lost servers include a member of
  every phase-one quorum and the leader, no replacement is possible.
- A server can answer a challenge and lose its state before the leader
  proposes the replacement. The leader then adds an incarnation that no
  longer runs. The next incarnation at the address asks again.
- `peace:form_cluster/3` is not atomic. Two calls at the same time are
  safe only if they use the same quorum system.
- A server does not start on stored state that was written before this
  work, because that state has no incarnation. There is no migration.

Done when: the milestone 2 limitation for a member whose storage failed is
removed, the new TLA+ cases are checked, and the simulation workload
passes.
