# peace formal models

This directory contains the TLA+ models of peace and the scripts that check
them.

| Model | Subject | Checked with |
|---|---|---|
| `FlexiblePaxos.tla` | The protocol in [`src/peace_core.erl`](../src/peace_core.erl) | TLC |
| `FlexiblePaxosInd.tla` | The same protocol, with an inductive invariant | Apalache, and TLC for refinement |
| `Reconfig.tla` | Membership change | TLC |
| `TraceFlexiblePaxos.tla` | One run of the code, checked against `FlexiblePaxos.tla` | TLC |

Section numbers refer to Heidi Howard's thesis,
[`docs/UCAM-CL-TR-935.pdf`](../docs/UCAM-CL-TR-935.pdf).

## Commands

| Command | What it runs | Time |
|---|---|---|
| `./check_all.sh quick` | Small configs, mutations and reachability checks | a few minutes |
| `./check_all.sh long` | Configs with millions of states | about 2 hours |
| `./check_all.sh soak` | The three-index membership config | about 8 hours |
| `./check.sh <Config> pass` | One config that must hold | |
| `./check.sh <Config> fail` | One config that must violate an invariant | |
| `./check_ind.sh all` | The inductive invariant | about 3 minutes |
| `./check_trace.sh <dir>` | One trace written by the simulation | about 1 second |

Requirements:

- Java 11 or later.
- TLC. The scripts use `$TLA2TOOLS_JAR` if it is set, then `tla2tools.jar`
  in this directory, then `vendor/tla2tools-v1.8.0.jar`.
- Apalache, for `check_ind.sh` only. It is not included in the repository
  because the release is 190 MB. The script uses `$APALACHE` if it is set,
  then `apalache-mc` on the path, then a release unpacked under
  `_build/apalache-dl`. The checks were run with Apalache 0.63.0.

### Skipping unchanged configs

A TLC result depends only on the model and the config. It does not depend on
anything in `src/`. `check_all.sh` therefore records each result in
[`checked.tsv`](checked.tsv) and skips a config whose inputs have not
changed.

- Each row holds the config name, the expected outcome, a hash of the
  inputs, the date, the number of distinct states, and the duration.
- The inputs are the config file, the two modules it uses, `check.sh`, and
  the name of the TLC jar. Comments and blank lines in the config and the
  modules are removed before hashing, so a change to a comment does not
  cause a run.
- `FORCE=1 ./check_all.sh <set>` runs every config in the set.
- The full TLC output of each run is kept in `logs/<Config>.log`. The `logs`
  directory is not committed.
- `checked.tsv` is committed. It is a record of past runs, not a proof. Use
  `FORCE=1` to reproduce a result.

`check_ind.sh` does the same with [`checked_ind.tsv`](checked_ind.tsv). Its
inputs are `FlexiblePaxosInd.tla`, `MCFlexiblePaxosInd.tla` and the script.
Comments are not removed from these modules, because Apalache reads its
type annotations from comments.

## The protocol model

`FlexiblePaxos.tla` is the protocol. The quorum systems are constants.
`MCFlexiblePaxos.tla` defines the quorum systems that `peace_quorum`
implements, so that a config can select one.

### What it models

- **Flexible quorums** (revision A, §4.1). `Quorum1` is the set of phase-one
  quorums and `Quorum2` is the set of phase-two quorums. The model does not
  assume that they intersect. Intersection is a property of the constants,
  so a config can violate it.
- **Multi-Paxos** (§3.6). One phase one covers the whole sequence. A promise
  carries every proposal the acceptor has accepted. Phase two runs per
  index.
- **Learning** (§3.3). An acceptor that knows an index is decided stores the
  value under a marker epoch, `Learned`, which is higher than every real
  epoch. An acceptor learns in three ways, as in the code:
  - The leader counts acceptances from a phase-two quorum (`LeaderLearn`).
  - A follower receives its leader's commit index and marks its entries from
    that leader's epoch as decided (`SendCommit`, `FollowerCommit`).
  - An acceptor copies a decided index from an acceptor that has it
    (`CatchUp`).
- **Stale leaders.** A leader can be deposed without receiving any message
  that tells it so. The model has two rules for this case, both controlled
  by the constant `ConflictStepDown`:
  - If the leader learns that an index was decided with a value different
    from its own proposal, it stops sending commit indexes. Otherwise a
    follower that holds the leader's proposal would treat it as decided.
  - The leader does not propose at an index it already holds as decided.
    Otherwise it could send a commit index that covers the index and then
    propose a different value there.

  In the code, the leader steps down in both cases.
- **Snapshots.** An acceptor can drop an index it knows is decided. Its
  later promises report that the index is dropped and do not report the
  value. A proposer does not propose at an index that any promise reported
  as dropped (`SnapshotGuard`). In the code, the candidate abandons its
  campaign and catches up. Snapshots are disabled (`Snapshots = FALSE`) in
  configs that test other things, to keep their state spaces small.
- **Message faults.** Messages can be lost, duplicated and reordered. The
  set `msgs` only grows, and no action is required to receive a message.

### What it does not model

| Not modelled | Reason |
|---|---|
| Crash and restart | `promised` and `accepted` are durable in peace, so a restarted acceptor behaves like a slow one. The simulation checks that the code persists state before it replies. |
| Election timing, heartbeats, pre-vote, quorum-loss step-down | These only restrict when an epoch starts or stops. The model allows an epoch to start at any time. |
| Read leases | They depend on clocks, and the model has no clocks. |
| Client replies, sessions, the state machine | Outside the consensus protocol. |
| Membership change | Modelled separately in `Reconfig.tla`. |
| Revisions B and C, and chapters 6 and 7 of the thesis | Not implemented in peace. |

### Properties

| Invariant | Meaning |
|---|---|
| `TypeOK` | Every variable has a value of the declared shape. |
| `Agreement` | At most one value is decided per index. |
| `LearnedSound` | A value that an acceptor has learned is the decided value. This is safe learning as defined in the thesis. |
| `LearnedAgree` | Learned entries are equal across acceptors. The simulation checks the same property on the code. |
| `OneValuePerEpoch` | An epoch proposes at most one value per index. |
| `QuorumIntersection` | Every phase-one quorum intersects every phase-two quorum (equation 4.4). |

### Configs

State counts are distinct states.

**Configs that must hold, quick set:**

| Config | Acceptors | Quorums (phase one / phase two) | Epochs × indexes | States |
|---|---|---|---|---|
| `FPaxosMajority` | 3 | 2 / 2 | 2 × 1 | 29 thousand |
| `FPaxosSingleton` | 3 | 3 / 1, Singleton Paxos (§4.3.2) | 2 × 1 | 5 thousand |
| `FPaxosAllAboard` | 3 | 1 / 3, All aboard Paxos (§4.3.2) | 2 × 1 | 30 thousand |
| `FPaxosEvenNodes` | 4 | 3 / 2, even nodes (§4.3.3) | 2 × 1 | 259 thousand |
| `FPaxosSnapshots` | 3 | 2 / 2, with snapshots | 2 × 1 | 180 thousand |

**Mutations, quick set.** Each mutation removes one safeguard and must
violate an invariant. `check.sh <Config> fail` requires an invariant
violation. A parse error or a crash does not count.

| Config | Change | Violates |
|---|---|---|
| `FPaxosUnsafeQuorums` | Quorums 2 / 1 over 3 acceptors, which do not always intersect | `Agreement` |
| `FPaxosNoFence` | An acceptor accepts a proposal below its promise | `Agreement` |
| `FPaxosNoConflictStepDown` | Both stale-leader rules are off (5 acceptors) | `LearnedSound` |
| `FPaxosNoSnapshotGuard` | A proposer proposes at an index that a promise reported as dropped | `Agreement` |

**Reachability checks, quick set.** Each config states an invariant that
says a certain state is never reached. TLC must violate it, which shows the
model can reach that state. Without these checks, the properties above could
hold only because the model does very little.

| Config | State that must be reachable |
|---|---|
| `FPaxosReachableDecided` | A value is decided |
| `FPaxosReachableAllLearned` | Every acceptor has learned every index |
| `FPaxosReachableRecovery` | A later epoch proposes a value that an earlier epoch decided |
| `FPaxosReachableConflict` | A leader learns a value different from its own proposal |
| `FPaxosReachableSnapshot` | An acceptor makes a promise after dropping an index |

**Configs that must hold, long set:**

| Config | Acceptors | Quorums | Epochs × indexes | States | Time |
|---|---|---|---|---|---|
| `FPaxosThreeEpochs` | 3 | 2 / 2 | 3 × 1 | 7.0 million | 2 minutes |
| `FPaxosGrid` | 4 | 2 × 2 grid (§4.1.3) | 2 × 1 | 13.0 million | 4 minutes |
| `FPaxosFiveAcceptors` | 5 | 3 / 3 | 2 × 1 | 6.4 million | 27 minutes |
| `FPaxosSingletonTwoIndexes` | 3 | 3 / 1 | 2 × 2 | 8.2 million | 6 minutes |
| `FPaxosMajorityTwoIndexes` | 3 | 2 / 2 | 2 × 2 | 67.9 million | 59 minutes |

These results are from 2026-11-11, after the model correction described in
the next section. The correction removes behaviours, so the counts are lower
than before it. `FPaxosMajorityTwoIndexes` had 116.9 million states and took
80 minutes before the correction.

TLC estimates the probability that a fingerprint collision hid a state. For
`FPaxosMajorityTwoIndexes` the estimate is 0.00014 from the observed
fingerprints and 0.0023 from its conservative formula. For the other four
runs it is less than 0.00001.

### Model correction of 2026-11-11

Until 2026-11-11 the model had the first stale-leader rule and not the
second. With every safeguard enabled, it violated `LearnedSound`.

The violation needs five acceptors. TLC finds it in 19 states:

1. Epoch 1 collects promises from a phase-one quorum.
2. Epoch 2 decides a value at index 1. The leader of epoch 1 receives none
   of these messages.
3. The leader of epoch 1 learns index 1 through `CatchUp`.
4. It sends a commit index that covers index 1. It has proposed nothing at
   index 1, so the first rule does not apply.
5. It proposes a different value at index 1. Phase one permits this because
   its promises reported index 1 as empty.
6. A fifth acceptor accepts that proposal, receives the commit index, and
   marks the proposal as decided. It now holds a value that was not decided.

Why the checks did not find it earlier:

- Every config that was required to hold had three or four acceptors. With
  fewer than five, no acceptor can be in the position of the fifth one.
- Five acceptors had been run only with `ConflictStepDown` off.

The code did not have this error. The simulation's churn workload had found
the same sequence in the code earlier. `peace_core` was changed at that time
to step down when it learns an index it has not proposed at, and
`deposed_leader_steps_down_on_unproposed_index_test` tests it. The rule was
not added to the model then.

Trace validation could not have found the error. It checks that the code
does only what the model permits, and here the model permitted too much.

The error was found while writing the inductive invariant. The clause about
commit messages, `CommitsSound`, was not inductive without the second rule.

Changes made:

- `Propose` has a new conjunct: the leader does not hold the index as
  decided.
- `FPaxosFiveAcceptors` was added to the long set. It fails without the
  conjunct and holds with it.

## The inductive invariant

TLC visits every reachable state. Its running time grows quickly with the
number of epochs and indexes. An inductive invariant avoids this. It is
checked with three implications, each over a single state or a single step:

| Check | Implication |
|---|---|
| `init` | `Init => IndInv` |
| `step` | `IndInv /\ Next => IndInv'` |
| `safe` | `IndInv => Agreement /\ LearnedSound /\ LearnedAgree` |

If all three hold, the safety properties hold in every reachable state of
every behaviour, of any length. [Apalache](https://apalache-mc.org) checks
the implications symbolically.

### The module

`FlexiblePaxosInd.tla` restates the protocol without the `msgs` set.
Apalache cannot type a set of records with different fields, so each kind of
message has its own variable.

TLC checks that the restatement is the same protocol.
`FPaxosIndRefines.tla` rebuilds `msgs` from the new variables, and TLC
checks that every behaviour of `FlexiblePaxosInd.tla` is a behaviour of
`FlexiblePaxos.tla` (2.1 million states, 85 seconds).

### The invariant

`IndInv` is the conjunction of these clauses:

| Clause | Meaning |
|---|---|
| `TypeOK` | Every variable has a value of the declared shape. |
| `PromisesSent` | An acceptor that sent a promise for an epoch has promised at least that epoch. |
| `AcceptsSent` | An acceptance refers to an existing proposal, and the acceptor's entry is from that epoch or a later one. |
| `EntriesAccepted` | An undecided entry equals the proposal of its epoch and was acknowledged. |
| `DroppedLearned` | An acceptor drops only indexes it has learned. |
| `PromisesHonest` | For an index that a promise did not report as dropped, the promise's report is still accurate for all epochs below the promised one. |
| `ProposalsSafe` | For every proposal and every earlier epoch, a phase-one quorum exists whose members either accepted the same value in that epoch or can no longer accept in it. This is the standard Paxos safety argument. |
| `CommitsSound` | If a commit was sent for an index, its leader holds that index as decided, and any proposal the leader made there equals the decided value. |
| `LearnedSound` | A learned value is the decided value. |

### Results

`./check_ind.sh all` runs the first six rows and the refinement check.

| Constants | Acceptors, quorums | Epochs × indexes | `step` time | TLC on the same bounds |
|---|---|---|---|---|
| `C3E2I2` | 3, 2 / 2 | 2 × 2 | 8 seconds | `FPaxosMajorityTwoIndexes`: 59 minutes |
| `C3E3I1` | 3, 2 / 2 | 3 × 1 | 6 seconds | `FPaxosThreeEpochs`: 2 minutes |
| `C5E2I1` | 5, 4 / 2 | 2 × 1 | 7 seconds | not run |
| `C3E3I3` | 3, 2 / 2 | 3 × 3 | 28 seconds | too large to finish |
| `NoGuard3` | 3, 2 / 2, without the new `Propose` conjunct | 2 × 1 | fails on `CommitsSound`, as required | holds |
| `Unsafe3` | 3, 2 / 1 | 2 × 1 | `safe` fails, as required | `FPaxosUnsafeQuorums` fails |
| `C5E3I3` | 5, 4 / 2 | 3 × 3 | 8 minutes | too large to finish |
| `C3E4I4` | 3, 2 / 2 | 4 × 4 | 8 minutes | too large to finish |

The times for `C5E3I3` and `C3E4I4` were measured while TLC was also running
on the same machine. The other times are from an idle machine.

`NoGuard3` shows a difference between the two methods. With three acceptors,
no behaviour reaches the error described above, so TLC reports no violation.
The `step` check still fails, because it starts from every state that
satisfies `IndInv`, including states that no behaviour reaches. This check
would have found the missing rule with three acceptors.

### Limitations

- The constants are fixed for each check. This is not a proof for every
  number of acceptors, epochs and indexes. That would require a proof
  system such as TLAPS.
- Quorum intersection is assumed of the constants.
- The module has only the `NoGuard3` and `Unsafe3` mutations. The other
  mutations are checked on `FlexiblePaxos.tla` with TLC.
- `Reconfig.tla` has no inductive invariant.

## The membership model

`Reconfig.tla` models `peace:change_members/3`. It was written and checked
before the code.

In the model, the members and the quorum system are decided in the log. A
change goes through a joint configuration. A candidate needs a phase-one
quorum of every configuration that its promises report. The module header
gives the safety argument.

The design is related to revision B of the thesis (§4.2). Revision B allows
quorums to differ between epochs. It does not specify how a proposer learns
the quorums of earlier epochs.

`MCReconfig.tla` sets the constants:

- Three acceptors.
- Two configurations with no members in common: `a1` and `a2` under
  `{counting, 1, 2}`, and `a3` alone.
- Two epochs, one value, and two or three indexes.
- The invariant is `LearnedAgree`.

### Separate roles

In these configs, any epoch can be prepared at any time, independent of what
its owner has promised. This is more general than peace.

| Config | Expected | Result | Set |
|---|---|---|---|
| `Reconfig` | holds | 44.3 million states, 25 minutes | long |
| `ReconfigNoJoint` | fails: the change skips the joint configuration | violated in seconds | quick |
| `ReconfigNoClosure` | fails: a candidate asks only the configuration it has applied | violated after about 13 million states, 6 minutes | long |
| `ReconfigReachableFinal` | fails: a change completes | seconds | long |
| `ReconfigReachableRaised` | fails: a promise adds a configuration the candidate must ask | seconds | long |

### Co-located roles

A peace server is a proposer and an acceptor at the same time (§3.7). A
candidate promises its own epoch when it sends the prepare, and accepts its
own proposals when it sends them. `CoLocated = TRUE` adds these two
constraints to the model.

The constraint restricts the model to what peace can do. The result is
weaker for the protocol in general and the same for peace. The state space
is about 20 times smaller.

| Config | Expected | Result | Set |
|---|---|---|---|
| `ReconfigCoLocated` | holds | 2.2 million states, about 1 minute | quick |
| `ReconfigCoLocatedNoJoint` | fails | seconds | quick |
| `ReconfigCoLocatedNoClosure` | fails | violated after 644 thousand states, seconds | quick |
| `ReconfigCoLocatedReachableFinal` | fails: a change completes | seconds | quick |
| `ReconfigCoLocatedReachableRaised` | fails: a promise adds a configuration the candidate must ask | seconds | quick |
| `ReconfigReachableAfterFinal` | fails: with three indexes, a value is decided after a completed change | seconds | quick |
| `ReconfigThreeIndexes` | holds | 414 million states, 8 hours 6 minutes | soak |

### Three indexes

Two indexes are enough for a complete change: the joint entry and the final
entry. They are not enough to decide a value after the change.
`ReconfigThreeIndexes` adds a third index, with co-located roles.
`ReconfigReachableAfterFinal` confirms that the model reaches a state where
a value is decided after a completed change.

Result of `ReconfigThreeIndexes` on 2026-11-11:

- No violation.
- 414,108,959 distinct states, 5.17 billion states generated, depth 34.
- 8 hours 6 minutes.
- TLC estimates the probability that a fingerprint collision hid a state at
  0.009 from the observed fingerprints and 0.11 from its conservative
  formula. This is a higher probability than for the other runs.

### An error in the first version

The first version of this model violated `LearnedAgree` in 19 steps with
both safeguards enabled. A deposed leader's joint entry lost its index to
another value. The leader then saw that index decided, treated its own joint
entry as decided, and proposed the final entry.

The model was missing the rule that a leader stops when it learns a value
different from its proposal. `FlexiblePaxos.tla` has this rule as
`ConflictStepDown`. The rule was added to `Reconfig.tla`. Membership change
depends on it.

### Limitations

- Three indexes are checked only with co-located roles. With separate roles
  the model is checked with two indexes.
- The model has one change, two epochs and one value.
- The commit index and snapshots are not in this model. Neither model
  combines them with membership change. The simulation tests the
  combination.

## Trace validation

Trace validation checks that a run of the code is a behaviour of
`FlexiblePaxos.tla`.

How it works:

1. The simulation records each step that each server takes.
2. [`dst/peace_dst_trace.erl`](../dst/peace_dst_trace.erl) converts the run
   into a sequence of model actions with their arguments. It derives them
   from the changes in each server's durable state and from the messages the
   server sent. It writes the sequence and the quorum system to
   `TraceData.tla`.
3. `TraceFlexiblePaxos.tla` has one behaviour, which takes the actions in
   order. After the last action of each step of the code, the model's
   `promised` and `accepted` must equal the server's.
4. `check_trace.sh <dir>` runs TLC. If TLC cannot take every action, the
   script prints the first action the model did not permit.

`make trace` validates 50 runs from three workloads:

- crashes, restarts and disconnections
- forced elections, partitions and delayed `learned` messages
- five servers under `{counting, 4, 2}`

The 50 runs contain about 38 thousand actions and include every action of
the model. `make trace` also runs four planted bugs, which must be rejected.
TLC takes about one second per run.

Because trace validation checks the code against the model, the long TLC
runs do not need to be repeated when only the code changes.

Limitations:

- The model's `msgs` contains every message sent. An action passes if the
  messages that justify it were sent, even if the server had not received
  them.
- When a heartbeat raises a server's promise, the trace uses the model's
  `Promise` action. In the model that action sends a promise message, which
  the code did not send.
- Only `FlexiblePaxos.tla` is covered. `Reconfig.tla` has no trace
  validation.

The header of `peace_dst_trace.erl` has the complete list.
