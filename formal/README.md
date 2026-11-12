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
  The same leader may also learn an index it has proposed nothing in. It
  must not then propose there: it could advertise a commit index over the
  index first and put its own value under it afterwards. The model's
  `Propose` refuses an index its leader already holds decided, under the
  same switch. Until 2026-11-11 it did not, and see "A hole in the model"
  below.
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

**A config is run again only when its inputs change.** TLC's answer depends
on the model and the config and on nothing in `src/`, so `check_all.sh`
keeps a ledger, [`checked.tsv`](checked.tsv): for each config, a hash of the
config, the two modules it instantiates, `check.sh` and the jar's name, with
the date and size of the run that last behaved as expected. A config whose
hash is in the ledger is reported and skipped. `FORCE=1` runs it anyway.
TLC's whole output from each run is left in `logs/<Config>.log`. The
ledger is committed, so a clone knows what was checked without spending the
hours again; it is a record, not a proof, and anyone who doubts it can force
the run. The rows for the four long `FPaxos` configs were written from the
run of 2026-11-10 described below, the files being unchanged since.

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
| `FPaxosFiveAcceptors` | 5 | 3 / 3 | 2 × 1 | 6.4 million |
| `FPaxosSingletonTwoIndexes` | 3 | 3 / 1 | 2 × 2 | 21.9 million |
| `FPaxosMajorityTwoIndexes` | 3 | 2 / 2 | 2 × 2 | 116.9 million |

`FPaxosFiveAcceptors` was run on 2026-11-11 with the fix described below.
The other four counts are from before that fix and are being run again.

Last run in full on 2026-11-10, after the models took the thesis's terms; the
counts are the same as before the renaming, as they should be. The first
three took 24 minutes together, `FPaxosThreeEpochs` and `FPaxosGrid` under
five each. `FPaxosMajorityTwoIndexes` took 1 hour 20 minutes: 1.27 billion
states generated, depth 35. At that size
TLC's own estimate of the chance that a fingerprint collision hid a state is
between 0.002 and 0.007, where for the others it is negligible.

## A hole in the model

Until 2026-11-11 `FlexiblePaxos.tla` had the first half of the stale-leader
guard and not the second, and with every safeguard on it violated
`LearnedSound`. Five acceptors are the fewest that can show it, and TLC does
in nineteen states: epoch 1 collects its promises; epoch 2 decides a value
at index 1 without it; epoch 1's leader, not knowing it is deposed, learns
the index by catching up, sends a commit index covering it, and only then
proposes there, which its phase one allows because its promises saw the
index empty; a fifth acceptor accepts that proposal, sees the commit index,
and holds as decided a value that was not.

Every config that was meant to hold had three or four acceptors, where the
deposed leader has no such follower. Five had only been run with the guard
off. `FPaxosFiveAcceptors` is the config that would have caught it, and is
now in the long set.

The code was never wrong in this way. The simulation's churn workload found
the same sequence in the code well before, `peace_core` was changed to step
down on learning an index it had not proposed in, and
`deposed_leader_steps_down_on_unproposed_index_test` has held it since. The
fix did not go back into the model, and nothing checked that it had. Trace
validation would not have caught it either: it checks that the code does
only what the model allows, and the model allowed too much. It was found
while writing an inductive invariant, whose clause for commit messages could
not be made true.

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
| `ReconfigNoClosure` | fails: a candidate asks only the configuration it has applied | violated after about 13 million states, 6 minutes |
| `ReconfigReachableFinal` | fails: a change completes | seconds |
| `ReconfigReachableRaised` | fails: a promise raises the bar | seconds |

`ReconfigNoJoint` is in the quick set and the rest in the long one. Run again
on 2026-11-11 after `CoLocated` was added to the module: `Reconfig` has the
same 44,286,932 states as before.

**Co-located roles.** In the model as first written a proposer is nobody in
particular: any epoch may be prepared at any time, whatever its owner has
promised. peace's servers are proposer and acceptor at once (§3.7), and a
candidate promises its own epoch as it sends the prepare, and accepts its own
proposals as it sends them. `CoLocated = TRUE` says that. It is a restriction
to what peace can do, so it proves less about the protocol in general and the
same about peace, and it is twenty times smaller:

| Config | Expect | Result |
|---|---|---|
| `ReconfigCoLocated` | holds | 2.2 million states, about a minute |
| `ReconfigCoLocatedNoJoint` | fails | seconds |
| `ReconfigCoLocatedNoClosure` | fails | violated after 644 thousand states, seconds |
| `ReconfigCoLocatedReachableFinal` | fails: a change completes | seconds |
| `ReconfigCoLocatedReachableRaised` | fails: a promise raises the bar | seconds |
| `ReconfigReachableAfterFinal` | fails: at three indexes, a value is decided after a completed change | seconds |

All of these are in the quick set.

The first version of this model failed, with both safeguards on, in nineteen
steps: a deposed leader whose joint entry had lost took the index being
decided for its entry being decided, and went on to `final`. The model had
left out the rule that a contradicted leader stops, which `FlexiblePaxos.tla`
has as `ConflictStepDown`. So membership change depends on that rule, and
the model now says so.

**Three indexes.** Two indexes are enough for a whole change, joint then
final, and for the final entry to be decided by the new configuration alone,
but not for a value after it. `ReconfigThreeIndexes` adds the third, with
co-located roles, and `ReconfigReachableAfterFinal` shows that a value
decided after a completed change is among the states it visits. It holds:
414,108,959 states, 5.17 billion generated, depth 34, 8 hours 6 minutes on
2026-11-11. It is in a set of its own, `./check_all.sh soak`. At that size
TLC's estimate of the chance that a fingerprint collision hid a state is
0.009 from the fingerprints it saw and 0.11 by its pessimistic formula, so
this is strong evidence and not certainty.

**Limits.** Three indexes were checked only with co-located roles; with
separate roles the model is checked to two. One change, two epochs, one
value. The commit index and snapshots are not in this model, and neither
model combines them with membership change. The simulation does.

## Trace validation

`TraceFlexiblePaxos.tla` follows one run of the code through
`FlexiblePaxos.tla`. [`dst/peace_dst_trace.erl`](../dst/peace_dst_trace.erl)
writes the run as `TraceData.tla`: the quorum system, and a sequence of the
model's actions with their arguments, derived from what each server's
durable state did at each step. The spec's only behaviour takes them in
order, and after the last action of each step of the code requires
`promised` and `accepted` to be what the server then held. TLC reaches the
end of the sequence or it does not; `check_trace.sh <dir>` says which, and
on a rejection prints the action the model refused.

`make trace` validates 50 runs of three workloads (crashes and cuts, forced
elections and rumours, and five servers under `{counting, 4, 2}`), some
38 thousand actions, every action of the model among them, and four planted
bugs that must be rejected. A run is about a second of TLC.

What a pass does not show is listed at the top of `peace_dst_trace.erl`. The
main one: the model's messages are all messages sent, so an action passes if
the messages that justify it were sent, whether or not the server had
received them.

This is why the long runs above need not be repeated when the code changes.
They are about the model. Whether the code is the model is checked here, in
minutes.

## Tooling

TLC from `vendor/tla2tools-v1.8.0.jar`, or `$TLA2TOOLS_JAR`, or a
`tla2tools.jar` dropped next to the scripts. Java 11 or later.
