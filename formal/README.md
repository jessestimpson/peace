# peace formal model

A TLA+ model of the protocol in [`src/peace_core.erl`](../src/peace_core.erl),
checked with TLC. TLC explores every interleaving of a small bounded cluster;
tests can only sample them. The [simulation harness](../dst/peace_dst.erl)
covers the other side: that the code implements this protocol.

Section numbers refer to Heidi Howard's thesis,
[`docs/UCAM-CL-TR-935.pdf`](../docs/UCAM-CL-TR-935.pdf).

## What it models

Two modules. `FlexiblePaxos.tla` is the protocol, with the quorum systems left
as constants. `MCFlexiblePaxos.tla` defines the quorum systems `peace_quorum`
implements, for a config to substitute.

- **Flexible quorums** (revision A, §4.1). `Quorum1` for promises, `Quorum2`
  for acceptances. Their intersection is *not* assumed: it is a property of
  the constants, so a config can break it.
- **Multi-Paxos** (§3.6). One phase one covers the whole sequence; a
  promise carries every proposal the acceptor has accepted. Phase two is per
  index.
- **Learning** (§3.3). An index an acceptor knows is decided is held under a
  marker epoch above every real one. Three routes, as in the code: the
  leader counts a phase-two quorum (`LeaderLearn`); a follower trusts its
  leader's commit index for entries from that leader's epoch (`SendCommit`,
  `FollowerCommit`); anybody copies a decided index from somebody who has it
  (`CatchUp`).
- **The stale-leader hazard.** A deposed leader that has not heard it was
  deposed can catch up an index that a later epoch decided differently from
  its own proposal. If it went on advertising a commit index over that index,
  a follower holding the old proposal would take it as decided.
  `ConflictStepDown` is the guard; peace steps down at that moment.
- **Snapshots.** An acceptor may drop a decided index, after which its
  promise says only that the index is dropped, not what it held. A proposer
  that read that as "free" could get a second value decided, so it does not
  propose in an index any promise reported dropped (`SnapshotGuard`); peace
  abandons the campaign and catches up. Off (`Snapshots = FALSE`) in the
  configs that are about something else, so their state spaces are as they
  were.
- **Faults.** Message loss, duplication and reordering: `msgs` only grows and
  nothing has to be received.

**Deliberately out of scope**: crash and restart (`promised` and `accepted`
are durable in peace, so a restarted acceptor is a slow one; the simulation
checks the code really does persist before it replies); election timing,
heartbeats, pre-vote and a leader stepping down for want of a quorum, all of
which only restrict when an epoch starts or stops and the model lets that
happen at any time; read leases, which rest on clocks the model does not
have; client replies, sessions and the state machine; membership change; and
the thesis beyond revision A.

## Checked properties

| Invariant | Meaning |
|---|---|
| `TypeOK` | state stays within declared shapes |
| `Agreement` | at most one value is ever decided per index |
| `LearnedSound` | the thesis's safe learning: what an acceptor has learned is the decided value |
| `LearnedAgree` | decided entries agree across acceptors; what the simulation checks on the code |
| `OneValuePerEpoch` | an epoch proposes one value per index |
| `QuorumIntersection` | every phase-one quorum meets every phase-two quorum (equation 4.4) |

## Configs

`./check_all.sh quick` runs the first three groups; `./check_all.sh long` the
last, and the membership model below. `./check.sh <Config> pass|fail` runs one. States are distinct states.

**Hold** (quick):

| Config | Acceptors | Quorums | Epochs × indexes | States |
|---|---|---|---|---|
| `FPaxosMajority` | 3 | 2 / 2 | 2 × 1 | small |
| `FPaxosSingleton` | 3 | 3 / 1, Singleton Paxos (§4.3.2) | 2 × 1 | 6 thousand |
| `FPaxosAllAboard` | 3 | 1 / 3, All aboard Paxos (§4.3.2) | 2 × 1 | 32 thousand |
| `FPaxosEvenNodes` | 4 | 3 / 2, even nodes (§4.3.3) | 2 × 1 | 366 thousand |
| `FPaxosSnapshots` | 3 | 2 / 2, with snapshots | 2 × 1 | 254 thousand |

**Mutations** (quick): each must fail, and `check.sh ... fail` demands a real
invariant violation, not a parse error.

| Config | Change | Violates |
|---|---|---|
| `FPaxosUnsafeQuorums` | quorums 2 / 1 over 3: they need not intersect | `Agreement` |
| `FPaxosNoFence` | an acceptor accepts below its promise | `Agreement` |
| `FPaxosNoConflictStepDown` | a contradicted leader keeps sending commits (5 acceptors) | `LearnedSound` |
| `FPaxosNoSnapshotGuard` | a proposer proposes in an index a promise reported dropped | `Agreement` |

**Reachability** (quick): each invariant denies a state the model has to be
able to reach for the properties above to mean anything, so each must fail.

| Config | Shows reachable |
|---|---|
| `FPaxosReachableDecided` | a value is decided |
| `FPaxosReachableAllLearned` | every acceptor learns every index |
| `FPaxosReachableRecovery` | a later epoch re-proposes a decided value |
| `FPaxosReachableConflict` | a leader finds itself contradicted, so the guard guards something |
| `FPaxosReachableSnapshot` | an acceptor promises after dropping an index, so that guard does too |

**Hold** (long):

| Config | Acceptors | Quorums | Epochs × indexes | States |
|---|---|---|---|---|
| `FPaxosThreeEpochs` | 3 | 2 / 2 | 3 × 1 | 13.0 million |
| `FPaxosGrid` | 4 | 2 × 2 grid (§4.1.3) | 2 × 1 | 16.0 million |
| `FPaxosSingletonTwoIndexes` | 3 | 3 / 1 | 2 × 2 | 21.9 million |
| `FPaxosMajorityTwoIndexes` | 3 | 2 / 2 | 2 × 2 | 116.9 million |

Last run in full on 2026-11-10, after the models took the thesis's terms; the
counts are the same as before the renaming, as they should be. The first
three took 24 minutes together, `FPaxosThreeEpochs` and `FPaxosGrid` under
five each. `FPaxosMajorityTwoIndexes` took 1 hour 20 minutes: 1.27 billion
states generated, depth 35. At that size
TLC's own estimate of the chance that a fingerprint collision hid a state is
between 0.002 and 0.007, where for the others it is negligible.

## Membership change

`Reconfig.tla` is a second model, for `peace:change_members/3`, written and
checked before the code. Members and quorum systems are decided in the log
and move through a joint configuration; a candidate needs a phase-one quorum
of every configuration its promises give it reason to respect. The header of
the module gives the argument. It is in the direction of the thesis's
revision B (§4.2), which lets quorums vary by epoch and leaves open how a
proposer learns what the earlier ones were.

`MCReconfig.tla` instantiates it with three acceptors and two configurations
that share nobody: `a1` and `a2` under `{counting, 1, 2}`, and `a3` alone.
Two epochs, two indexes, one value. The invariant is `LearnedAgree`.

| Config | Expect | Result |
|---|---|---|
| `Reconfig` | holds | 44.3 million states, 25 minutes |
| `ReconfigNoJoint` | fails: straight to the new configuration | violated in seconds |
| `ReconfigNoClosure` | fails: a candidate asks only the configuration it has applied | violated after 13.9 million states, 6 minutes |
| `ReconfigReachableFinal` | fails: a change completes | seconds |
| `ReconfigReachableRaised` | fails: a promise raises the bar | seconds |

`ReconfigNoJoint` is in the quick set and the rest in the long one.

The first version of this model failed, with both safeguards on, in nineteen
steps: a deposed leader whose joint entry had lost took the index being
decided for its entry being decided, and went on to `final`. The model had
left out the rule that a contradicted leader stops, which `FlexiblePaxos.tla`
has as `ConflictStepDown`. So membership change depends on that rule, and
the model now says so.

**Limits.** Two indexes are enough for a whole change, joint then final, and
for the final entry to be decided by the new configuration alone, but not
for a value after it; three indexes did not finish. The commit index and
snapshots are not in this model, and neither model combines them with
membership change. The simulation does.

## Tooling

TLC from `vendor/tla2tools-v1.8.0.jar`, or `$TLA2TOOLS_JAR`, or a
`tla2tools.jar` dropped next to the scripts. Java 11 or later.
