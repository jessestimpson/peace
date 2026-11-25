# Verified properties of peace

This file lists the properties of peace that a mechanical check supports.
It follows the [verified_md](https://github.com/jessestimpson/verified_md) convention.

| Field | Value |
|---|---|
| Version of peace | 0.1.0 |
| Detailed sources | [README.md](README.md), "Verification"; [formal/README.md](formal/README.md); [jepsen/README.md](jepsen/README.md) |

## How to read this file

1. A reader can treat each statement under "Verified properties" as true
   for the version of peace in the same commit as this file, within the
   bound that the entry states and under the assumptions in "Assumptions".
2. An entry is not verified beyond its bound. The entry can be true or
   false there. An entry with the method `TLC` for three acceptors does
   not state anything about seven acceptors.
3. A property that is not in this file is not verified. The property can
   be true or false. "Not verified" lists the properties that a reader is
   most likely to assume.
4. Each entry has an identifier, such as `C1`. The identifier does not
   change when the file is edited.
5. "Reproduction" gives the date of the last recorded run of each check
   that GitHub Actions does not run on each push. No later run supports
   the entries of that check.

## Methods

Each entry names the methods that support it.

| Method | Check | What a pass shows | What a pass does not show |
|---|---|---|---|
| `TLC` | TLC visits every reachable state of a TLA+ model. | The property holds in every reachable state of the model, for the constants of the config. | Anything about other constants, or about the code. |
| `IND` | Apalache checks an inductive invariant of the protocol model: `Init => IndInv`, `IndInv /\ Next => IndInv'`, and `IndInv => ` the property. | The property holds in every reachable state of every behaviour of the model, of any length, for the constants of the check. | Anything about other constants, or about the code. Quorum intersection is assumed of the constants. |
| `TRACE` | TLC checks that a simulated run of the code is a behaviour of `FlexiblePaxos.tla`, and that the promise and the accepted entries of each server equal the state of the model after each step. | In that run, the code took only steps that the model permits. | Anything about a run that was not checked, or about a feature that the model does not contain. |
| `SIM` | The real `peace_server` processes run under [eta](https://github.com/jessestimpson/eta) with a seeded scheduler, a virtual clock, message loss and delay, kills, restarts and a simulated disk. The harness checks invariants after every step. | The invariant held at every step of every run. | Anything about a schedule that no seed produced. |
| `PORC` | [Porcupine](https://github.com/anishathalye/porcupine) checks the client history of a simulated run for linearizability. | The history is linearizable. Porcupine reads only what the clients observed. | Anything about a history that was not checked. |
| `JEPSEN` | A [Jepsen](https://github.com/jepsen-io/jepsen) test runs a key-value store on five Docker nodes with real files and real distribution. Knossos checks the history of each key. `jepsen/recheck.sh` checks the same histories with Porcupine. | The history of each key is linearizable. | See "Limitations". |
| `UNIT` | EUnit tests in [test/](test/). | The named case behaves as stated. | Anything about other cases. |

`TLC` and `IND` are exhaustive within their bounds. `TRACE`, `SIM`, `PORC`,
`JEPSEN` and `UNIT` are tests: each one checks a finite set of runs.

## Assumptions

Every entry holds only under these assumptions.

- **A1. Stored state is durable.** A server that restarts with its stored
  state finds the state that it last synced. A server that has lost its
  stored state is covered by `I1` to `I4`. A data directory that is
  restored from a backup violates this assumption, and peace does not
  detect it.
- **A2. The state machine is deterministic.** `apply/3` returns the same
  result on every server.
- **A3. No Byzantine faults.** A server runs the code of peace. A message
  is lost, delayed, duplicated or reordered, and is not altered.
- **A4. The quorum system intersects.** Every phase-one quorum intersects
  every phase-two quorum (equation 4.4 of the thesis). `Q1` states what
  peace checks at the start of a server.
- **A5. Clock rates, for read leases only.** The clock rates of the
  servers differ by less than one tenth. No other entry depends on clocks.
- **A6. A release build.** The configuration keys that plant bugs are
  compiled only when `TEST` is defined.
- **A7. One version of the session rules.** Every member runs the same
  version of the session rules.
- **A8. The dependencies behave as "Dependencies" states.** No dependency
  of peace has a `VERIFIED.md`.

## Dependencies

No dependency of peace has a `VERIFIED.md`. peace therefore relies on no
entry of another project. The first table lists the software that peace
runs on. The second table lists the tools that the checks use. Each row
states the behaviour that this file assumes, and no check in peace verifies
that behaviour.

Software that peace runs on:

| Dependency | Version | Used for | Behaviour assumed | Treatment in each method |
|---|---|---|---|---|
| Erlang/OTP: the emulator, `kernel` and `stdlib` | 28.3 in GitHub Actions, 28 in the Jepsen test | Processes, distribution, files, timers and the monotonic clock | A message between two processes is not altered. `file:sync/1` and `file:datasync/1` return after the data is on the disk. The monotonic clock does not go backwards. | `UNIT`, `JEPSEN`: included. `SIM`, `TRACE`, `PORC`: eta replaces the scheduler, the clock, the network and the disk. `TLC`, `IND`: not in the models. |
| dets, in `stdlib` | The same | The `peace_storage_dets` backend | A dets file holds the objects that were written before the last sync. | `UNIT`: included. `SIM`: replaced by `eta_dets`. `JEPSEN`: not used. |
| The operating system and the disk | Not fixed | Storage of the write-ahead log and the dets files | Data that was synced is read back unchanged after a restart. This is assumption `A1`. | `UNIT`: included, with injected faults in the write-ahead log tests. `SIM`: replaced by the simulated disk of eta. `JEPSEN`: included, on one shared disk. |

peace declares no other dependency. `rebar.config` has an empty `deps`
list outside the `dst` profile.

Tools that the checks use:

| Tool | Version | Methods | Behaviour assumed |
|---|---|---|---|
| [eta](https://github.com/jessestimpson/eta) | The `main` branch. No commit is fixed. | `SIM`, `TRACE`, `PORC` | A run is determined by its seed. The simulated network, clock and disk produce only faults that a real system can produce, and the simulated disk loses only data that was not synced. |
| TLC | `tla2tools` 1.8.0 | `TLC`, `TRACE` | TLC visits every reachable state of a model and reports every violation of an invariant, except for a state that a fingerprint collision hides. |
| [Apalache](https://apalache-mc.org) | 0.63.0 | `IND` | Apalache reports a counterexample to an implication if one exists for the constants. |
| [Porcupine](https://github.com/anishathalye/porcupine) | 1.3.1 | `PORC`, and the second check of `JEPSEN` | Porcupine accepts a history only if the history is linearizable with respect to the model that it is given. |
| [Jepsen](https://github.com/jepsen-io/jepsen), with Knossos | 0.3.9 | `JEPSEN` | Jepsen records the history that the clients observed. Knossos accepts a history only if the history is linearizable. |
| EUnit | The version in Erlang/OTP | `UNIT`, and the runner of `SIM`, `TRACE` and `PORC` | A test that fails is reported as failed. |

A fault in a tool can make a check pass when the property does not hold.
"Evidence that the checks can fail" shows that each tool rejects at least
one planted fault. It does not show that the tool rejects every fault.

## Verified properties

### Consensus: the protocol model

The model is [formal/FlexiblePaxos.tla](formal/FlexiblePaxos.tla). It
contains flexible quorums (§4.1 of the thesis), Multi-Paxos (§3.6),
learning (§3.3), leaders that are deposed without a message, snapshots, and
messages that are lost, duplicated and reordered.

| Id | Property | Method | Bound |
|---|---|---|---|
| `C1` | Agreement. At most one value is decided for each index. | `TLC`, `IND` | See "Bounds of the protocol model". |
| `C2` | Safe learning (`LearnedSound`). A value that an acceptor has learned is the decided value. | `TLC`, `IND` | The same. |
| `C3` | Learned entries are equal across acceptors (`LearnedAgree`). | `TLC`, `IND` | The same. |
| `C4` | An epoch proposes at most one value for each index (`OneValuePerEpoch`). | `TLC` | The `TLC` configs only. |
| `C5` | `C1` to `C4` hold when acceptors drop decided indexes into a snapshot. | `TLC` | 3 acceptors, quorums 2 / 2, 2 epochs, 1 index. |
| `C6` | Every behaviour of `FlexiblePaxosInd.tla`, the model that `IND` checks, is a behaviour of `FlexiblePaxos.tla`. | `TLC` | 2.1 million states. |

Bounds of the protocol model:

| Method | Acceptors | Quorums (phase one / phase two) | Epochs × indexes |
|---|---|---|---|
| `TLC` | 3 | 2 / 2 | 2 × 1, 3 × 1, 2 × 2 |
| `TLC` | 3 | 3 / 1, Singleton Paxos | 2 × 1, 2 × 2 |
| `TLC` | 3 | 1 / 3, All aboard Paxos | 2 × 1 |
| `TLC` | 4 | 3 / 2, even nodes | 2 × 1 |
| `TLC` | 4 | 2 × 2 grid | 2 × 1 |
| `TLC` | 5 | 3 / 3 | 2 × 1 |
| `IND` | 3 | 2 / 2 | 2 × 2, 3 × 1, 3 × 3 |
| `IND` | 5 | 4 / 2 | 2 × 1 |
| `IND`, run once and not in `check_ind.sh all` | 3 | 2 / 2 | 4 × 4 |
| `IND`, run once and not in `check_ind.sh all` | 5 | 4 / 2 | 3 × 3 |

### Consensus: the code

| Id | Property | Method | Bound |
|---|---|---|---|
| `K1` | A run of the code is a behaviour of `FlexiblePaxos.tla`. `C1` to `C4` therefore hold for that run. | `TRACE` | 250 runs: 20 of the faults workload, 20 of the churn workload, 10 with `{counting, 4, 2}` over 5 servers, 100 with gates, 100 with passive servers. |
| `K2` | No index is decided with two different values, by any server, at any time in a run (`agreement`). | `SIM` | Every run of every workload. See "Simulation workloads". |
| `K3` | The durable promise of a server never decreases (`promise_never_regresses`). | `SIM` | The same. |
| `K4` | The machine of a server has applied exactly the decided values up to the commit index of the server, in order (`applied_matches_decided`). This includes a server that received a snapshot. | `SIM` | The same. |
| `K5` | When a client receives `{ok, Index}`, the value of that client is decided at that index (`acknowledged_is_decided`). | `SIM` | The same. |
| `K6` | At the end of a run in which the faults stop, every server has applied the same indexes and has the same machine state, and at least one value was acknowledged. | `SIM` | Runs with `converge` on. |
| `K7` | A leader that learns a value at an index where the leader has not proposed steps down. | `UNIT` | `deposed_leader_steps_down_on_unproposed_index_test`, a replay of the counterexample of TLC. |

### Durability

| Id | Property | Method | Bound |
|---|---|---|---|
| `D1` | A server has sent a storage write for every change to its promise, its accepted entries and its snapshot index (`storage_matches_memory`). | `SIM` | Every run with the dets backend or the write-ahead log backend. |
| `D2` | `K2` to `K5` hold when a killed node loses the file data and the directory operations that the node did not sync. | `SIM` | The write-ahead log workload, on the simulated disk of eta. |
| `D3` | A server whose storage write fails stops, sends no message that depends on the write, and is not restarted. | `UNIT` | |
| `D4` | The write-ahead log handles a failed sync, a short write, a full disk, a torn write, a damaged record, a damaged header, a damaged checkpoint and a failed checkpoint as [README.md](README.md), "Storage", states. | `UNIT` | Injected faults on real files. |
| `D5` | Both durable backends recover the stored state after a close and after a kill. | `UNIT` | Real files. |

### Linearizability

| Id | Property | Method | Bound |
|---|---|---|---|
| `L1` | The client history of appends and consistent reads is linearizable. | `PORC` | 520 simulated runs, 21,122 operations. Workloads: faults, churn, `{counting, 4, 2}`, read leases with clocks 6 per cent fast, membership change, gates, passive servers, formation with a machine state. |
| `L2` | A consistent query returns a prefix of the decided log that contains every value acknowledged before the query was issued (`linearizable_read`). | `SIM` | Every run. |
| `L3` | The history of each key of a key-value store on real nodes is linearizable under partitions, kills, pauses, membership changes and changes of the quorum system. | `JEPSEN` | 15 runs of 30 to 300 seconds on 2026-11-12 to 2026-11-14, with majority, `{counting, 4, 2}`, `{counting, 2, 4}`, grid and weighted quorums. |
| `L4` | The same as `L3`, over 24 hours. | `JEPSEN` | 135 runs of 600 seconds on commit `4d31a87`. 9,070 keys, 444,796 acknowledged operations. Porcupine found every key linearizable. Knossos checked 81 runs completely and ran out of memory on 161 keys in the other 54 runs. |

### Sessions

| Id | Property | Method | Bound |
|---|---|---|---|
| `S1` | No machine applies a value of a session twice, regardless of how many indexes hold the value because of client retries (`applied_once`). | `SIM` | Every run. Clients retry with sessions in every workload. |
| `S2` | Every machine applies the values of one session process in the order in which the client submitted them, with no value left out (`session_order`). | `SIM` | The three workloads with session processes: faults, faults with `max_pending` of 2, and churn. |
| `S3` | The session rules handle values decided out of order, and copies inside and outside the reply window. | `UNIT` | |

`S1` does not hold for a session that the cluster evicted. See "Not
verified".

### Read leases

| Id | Property | Method | Bound |
|---|---|---|---|
| `R1` | A read that a leader answers under a lease is linearizable when clock rates are within assumption `A5`. | `SIM`, `PORC`, `UNIT` | `SIM` and `PORC`: two of three servers with clocks 6 per cent fast, 30 runs in `PORC`. `UNIT`: follower clocks 10 per cent fast. |
| `R2` | The checks detect a read lease that is not safe. | `SIM`, `UNIT` | `SIM`: clocks that differ in rate by a factor of ten produce a violation. `UNIT`: follower clocks 25 per cent fast produce a stale read. |
| `R3` | A read lease on real nodes with a clock rate spread of 8 per cent and wall clock skew is linearizable. | `JEPSEN` | 1 run of 300 seconds. The clock rate is changed inside peace and not in the emulator. |

### Quorum systems

| Id | Property | Method | Bound |
|---|---|---|---|
| `Q1` | `peace_quorum:validate/2` accepts a counting quorum system if and only if `Q1 + Q2 > N`. | `UNIT` | Every `Q1` and `Q2` for 1 to 7 members (`exhaustive_matches_arithmetic_test`). |
| `Q2` | Quorums that do not intersect violate `C1`. Quorum intersection is therefore necessary. | `TLC`, `IND`, `SIM`, `TRACE`, `PORC` | Each method rejects the planted bug. |
| `Q3` | A custom quorum module (`{module, Mod, Arg}`) with weights gives linearizable histories. | `JEPSEN` | 1 run of 180 seconds, and the runs with `quorums` faults. |

### Membership change

The model is [formal/Reconfig.tla](formal/Reconfig.tla). It is separate
from the protocol model.

| Id | Property | Method | Bound |
|---|---|---|---|
| `M1` | Learned entries are equal across acceptors (`LearnedAgree`) through a change between two configurations that have no member in common, through a joint configuration. | `TLC` | 3 acceptors, 2 epochs, 1 value, 1 change. 2 indexes with separate roles (44.3 million states). 3 indexes with co-located roles (414 million states). |
| `M2` | A change without a joint configuration violates `M1`. A candidate that asks only the configuration it has applied violates `M1`. | `TLC` | Mutations `ReconfigNoJoint` and `ReconfigNoClosure`. |
| `M3` | `K2` to `K5` and `L2` hold across membership changes in the code. | `SIM` | The membership workload: five configurations of five servers, with different members, more members, fewer members, no member in common, and a different quorum system. |
| `M4` | Client histories are linearizable across membership changes. | `PORC`, `JEPSEN` | `PORC`: 30 runs, and 60 runs with formation with a machine state. `JEPSEN`: the runs with `members` and `quorums` faults. |

### Member identity and replacement

The model is [formal/Replace.tla](formal/Replace.tla). An acceptor in the
model is one incarnation of a server.

| Id | Property | Method | Bound |
|---|---|---|---|
| `I1` | `LearnedAgree` holds when any running acceptor can lose its state, stop and be replaced. | `TLC` | 4 acceptors, 2 configurations with majority quorums, 2 epochs, 1 value, 2 indexes, co-located roles (32.6 million states). |
| `I2` | An acceptor that a joint entry adds ran at some time after the epoch that introduced the entry started (`ReplacementIsLive`). A delayed request of an incarnation that no longer runs replaces no member. | `TLC`, `SIM` | `TLC`: the bound of `I1`. `SIM`: `replacement_is_live`, in every run. The storage loss workload delivers such requests. |
| `I3` | An acceptor that loses its state and keeps its identity violates `LearnedAgree`. The incarnation is therefore necessary. | `TLC`, `SIM`, `TRACE` | Mutation `ReplaceSameIdentity` and the planted bug. |
| `I4` | `K2` to `K5` hold when every restart of a server loses the disk of the server, and the server asks to replace the member that it was. | `SIM` | The storage loss workload. In 80 runs the storage backend supplies the incarnation. |
| `I5` | A server drops a message for another incarnation. A server does not start on stored state without an identity. A replacement keeps the row of the member in a grid. | `UNIT` | |

### Extension points of member identity

| Id | Property | Method | Bound |
|---|---|---|---|
| `E1` | While a server is passive, or its gate is closed, the promise of the server does not change and the server accepts no entry (`silent_accepts_nothing`). | `SIM` | 400 runs with passive servers, 500 runs with gates. |
| `E2` | A run with passive servers or gates is a behaviour of `FlexiblePaxos.tla`, which has no passive server and no gate. | `TRACE` | 200 of the 250 runs of `K1`. |
| `E3` | Client histories are linearizable with gates, with passive servers, and with formation with a machine state. | `PORC` | 100, 100 and 160 runs. |
| `E4` | `K2` to `K5` hold for a cluster that is formed with a machine state, on every founder or on the first founder only. | `SIM` | 500 runs, with restarts, lost disks and membership changes. |

### Versions and upgrade

| Id | Property | Method | Bound |
|---|---|---|---|
| `V1` | `K2` to `K5` hold while servers are killed and started again with a later or an earlier range of message versions, one server at a time. | `SIM` | 500 runs. The message versions exist only in a test build. |
| `V2` | After an upgrade with no other fault, every server holds every decided value. | `SIM` | 200 of the 500 runs. |
| `V3` | A server drops a message of a version outside its range and a message without a version. A server does not start on stored data of a later format. | `UNIT` | |

### Snapshots and overload

| Id | Property | Method | Bound |
|---|---|---|---|
| `N1` | `K2` to `K5` hold when servers take a snapshot every five indexes, send a snapshot in chunks of 48 bytes and store a snapshot in at least two steps. | `SIM` | Every run. |
| `N2` | A candidate that leads while behind a snapshot violates `C1`. | `TLC`, `SIM`, `TRACE` | Mutation `FPaxosNoSnapshotGuard` and the planted bug. |
| `N3` | The transfer of a snapshot handles a lost request, a repeated chunk, a damaged chunk and a transfer that replaces another transfer. | `UNIT` | |
| `N4` | `K2` to `K5`, `S1` and `S2` hold when a server refuses client requests because of `max_mailbox` or `max_pending`. | `SIM` | `max_mailbox` of 1 and 2, `max_pending` of 2. |
| `N5` | A server with a mailbox limit keeps the oldest requests in order and refuses the newest. | `UNIT` | |

## Simulation workloads

The entries with the method `SIM` and the bound "every run" refer to these
workloads of [dst/peace_dst.erl](dst/peace_dst.erl): faults, churn,
membership, dets, write-ahead log, storage loss, gates, passive servers,
formation with a machine state, and upgrade. [README.md](README.md),
"Deterministic simulation", describes each one.

## Evidence that the checks can fail

A check that cannot fail supports no property. Each method is run against
changes that must make it fail.

| Method | Changes that the method must reject | Count |
|---|---|---|
| `TLC` | Mutations of the models, each of which removes one safeguard | 8 mutations in 10 configs |
| `TLC` | Reachability checks, each of which shows that the model reaches a state that the properties depend on | 11 configs |
| `IND` | Quorums that do not intersect, and the model without the second stale-leader rule | 2 |
| `SIM` | Planted bugs in the code or the harness | 17 |
| `TRACE` | Planted bugs | 4 |
| `PORC` | Planted bugs | 3 |
| `JEPSEN` | Nodes that answer reads from local state (`--stale-reads`) | 1 |

`TRACE` rejects 30 of 30 runs with quorums that do not intersect, 22 of 30
runs with a server that keeps its incarnation after it loses its disk, 13
of 60 runs without the snapshot guard, and 3 of 60 runs with a deposed
leader that does not step down.

## Not verified

- **Liveness.** No model has a liveness property. `K6` is the only entry
  about progress, and it is a test.
- **A proof for every cluster size.** `IND` fixes the number of acceptors,
  epochs and indexes for each check. There is no TLAPS proof.
- **An inductive invariant for membership change.** `Reconfig.tla` and
  `Replace.tla` are checked with `TLC` only, with 1 change, 2 epochs and
  1 value.
- **Models of these features.** No TLA+ model contains read leases,
  sessions, the state machine, client replies, the formation of a cluster,
  election timing, pre-vote, quorum-loss step-down, gates or passive
  servers. `SIM`, `PORC` and `UNIT` cover them.
- **Membership change combined with the commit index and snapshots, in a
  model.** `SIM` tests the combination.
- **Trace validation of membership change.** `TRACE` covers only
  `FlexiblePaxos.tla`.
- **A replacement that an operator requests.** `peace:replace_member/2`
  makes the replacement without a challenge. `Replace.tla` does not
  contain it.
- **A data directory restored from a backup.** The directory keeps its
  incarnation and has lost the promises made after the backup.
- **Sessions after eviction.** A copy of the first value of an evicted
  session that is decided later is applied again.
- **Read leases outside assumption `A5`.** The Jepsen test has no run that
  shows a violation when clock rates exceed the assumption.
- **A clock that jumps or changes rate while a node runs**, in the Jepsen
  test.
- **Storage operations that fail, in the simulation.** `UNIT` covers them.
- **Real dets in the simulation.** The simulation uses the replacement for
  dets in eta. `UNIT` covers real dets.
- **The extension points and the upgrade procedure in the Jepsen test.**
- **Files that are corrupted on real nodes.** The Jepsen test does not
  corrupt files.
- **Nodes on separate machines.** The Jepsen test runs all containers on
  one machine.
- **Performance.** [bench/README.md](bench/README.md) holds measurements,
  not verified bounds.
- **Revision B, revision C, and chapters 6 and 7 of the thesis.** peace
  does not implement them.

## Limitations

- `TLC` and `IND` verify the models. `TRACE` connects the code to
  `FlexiblePaxos.tla` for 250 runs. No method proves that the code
  implements a model.
- `TRACE` passes an action if the messages that justify the action were
  sent, even if the server had not received them.
- A server in a run of `TRACE` waits for every storage write. `SIM` and
  `JEPSEN` cover writes that are in progress.
- `E1` compares with the next state that a server publishes after its gate
  closes. A promise or an acceptance in the group of events that the
  server was handling at that moment is not detected.
- `PORC` checks an append with an unknown outcome only if a read returned
  its value.
- The model of the machine that `PORC` uses is part of this repository.
- TLC estimates the probability that a fingerprint collision hid a state.
  The estimate is 0.009 for `ReconfigThreeIndexes` (0.11 from the
  conservative formula), 0.00014 for `FPaxosMajorityTwoIndexes`, and less
  than 0.00001 for the other long configs of the protocol model.
- A kill in the Jepsen test does not discard data that was written and not
  synced. `D2` covers that case.

## Reproduction

| Method | Command | Time | Runs in GitHub Actions | Last recorded run |
|---|---|---|---|---|
| `UNIT` | `make test` | seconds | Yes, on each push | |
| `SIM` | `make dst` | about 7 minutes | Yes, on each push | |
| `TRACE` | `make trace` | about 7 minutes | Yes, on each push | |
| `PORC` | `make porcupine` | about 11 minutes | No. One history needs 17 GB of memory. | |
| `TLC`, quick set | `make tlc` | a few minutes | Yes, on each change in `formal/` | 2026-11-14, [formal/checked.tsv](formal/checked.tsv) |
| `TLC`, long set | `make tlc-long` | about 2.5 hours | On a manual start | 2026-11-14, [formal/checked.tsv](formal/checked.tsv) |
| `TLC`, `ReconfigThreeIndexes` | `make tlc-soak` | about 8 hours | No | 2026-11-15, [formal/checked.tsv](formal/checked.tsv) |
| `IND` | `make ind` | about 3 minutes | No. Apalache is not in the repository. | 2026-11-11, [formal/checked_ind.tsv](formal/checked_ind.tsv) |
| `JEPSEN` | `make jepsen`, `jepsen/soak.sh 24` | minutes per run | No | 2026-11-20, commit `4d31a87` |

A TLC result depends only on the model and the config, and not on the
code. `TRACE` checks the code against the model on each push.

## Maintenance

1. A change that adds, removes or weakens a check updates this file in the
   same commit.
2. A change that makes an entry false removes the entry or narrows its
   bound in the same commit.
3. An entry is added only when a check that can fail supports it.
4. A run of a check that GitHub Actions does not run on each push updates
   the "Last recorded run" column in "Reproduction".
