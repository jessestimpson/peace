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
- **Multi-decree Paxos** (§3.6). One phase 1 covers the whole log; a 1b
  carries every vote the acceptor holds. Phase 2 is per slot.
- **Learning** (§3.3). A slot an acceptor knows is chosen is held under a
  marker ballot above every real one. Three routes, as in the code: the
  leader counts a phase-2 quorum (`LeaderDecide`); a follower trusts its
  leader's commit index for entries from that leader's ballot (`SendCommit`,
  `FollowerCommit`); anybody copies a decided slot from somebody who has it
  (`CatchUp`).
- **The stale-leader hazard.** A deposed leader that has not heard it was
  deposed can catch up a slot that a later ballot decided differently from
  its own proposal. If it went on advertising a commit index over that slot,
  a follower holding the old proposal would take it as decided.
  `ConflictStepDown` is the guard; peace steps down at that moment.
- **Faults.** Message loss, duplication and reordering: `msgs` only grows and
  nothing has to be received.

**Deliberately out of scope**: crash and restart (`promised` and `accepted`
are durable in peace, so a restarted acceptor is a slow one; the simulation
checks the code really does persist before it replies); election timing,
heartbeats, client replies and the state machine; membership change; and the
thesis beyond revision A.

## Checked properties

| Invariant | Meaning |
|---|---|
| `TypeOK` | state stays within declared shapes |
| `Agreement` | at most one value is ever chosen per slot |
| `DecidedSound` | whatever an acceptor holds as decided is the chosen value |
| `DecidedAgree` | decided entries agree across acceptors; what the simulation checks on the code |
| `OneValuePerBallot` | a ballot proposes one value per slot |
| `QuorumIntersection` | every phase-1 quorum meets every phase-2 quorum (equation 4.4) |

## Configs

`./check_all.sh quick` runs the first three groups; `./check_all.sh long` the
last. `./check.sh <Config> pass|fail` runs one. States are distinct states.

**Hold** (quick):

| Config | Acceptors | Quorums | Ballots × slots | States |
|---|---|---|---|---|
| `FPaxosMajority` | 3 | 2 / 2 | 2 × 1 | small |
| `FPaxosSingleton` | 3 | 3 / 1, Singleton Paxos (§4.3.2) | 2 × 1 | 6 thousand |
| `FPaxosAllAboard` | 3 | 1 / 3, All aboard Paxos (§4.3.2) | 2 × 1 | 32 thousand |
| `FPaxosEvenNodes` | 4 | 3 / 2, even nodes (§4.3.3) | 2 × 1 | 366 thousand |

**Mutations** (quick): each must fail, and `check.sh ... fail` demands a real
invariant violation, not a parse error.

| Config | Change | Violates |
|---|---|---|
| `FPaxosUnsafeQuorums` | quorums 2 / 1 over 3: they need not intersect | `Agreement` |
| `FPaxosNoFence` | an acceptor accepts below its promise | `Agreement` |
| `FPaxosNoConflictStepDown` | a contradicted leader keeps sending commits (5 acceptors) | `DecidedSound` |

**Reachability** (quick): each invariant denies a state the model has to be
able to reach for the properties above to mean anything, so each must fail.

| Config | Shows reachable |
|---|---|
| `FPaxosReachableChosen` | a value is chosen |
| `FPaxosReachableAllLearned` | every acceptor learns every slot |
| `FPaxosReachableRecovery` | a later ballot re-proposes a chosen value |
| `FPaxosReachableConflict` | a leader finds itself contradicted, so the guard guards something |

**Hold** (long):

| Config | Acceptors | Quorums | Ballots × slots | States |
|---|---|---|---|---|
| `FPaxosThreeBallots` | 3 | 2 / 2 | 3 × 1 | 13.0 million |
| `FPaxosGrid` | 4 | 2 × 2 grid (§4.1.3) | 2 × 1 | 16.0 million |
| `FPaxosSingletonTwoSlots` | 3 | 3 / 1 | 2 × 2 | 21.9 million |
| `FPaxosMajorityTwoSlots` | 3 | 2 / 2 | 2 × 2 | 116.9 million |

The first three took about 25 minutes together on a busy machine,
`FPaxosThreeBallots` under five of them. `FPaxosMajorityTwoSlots` took 1 hour
16 minutes on its own: 1.27 billion states generated, depth 35. At that size
TLC's own estimate of the chance that a fingerprint collision hid a state is
between 0.002 and 0.007, where for the others it is negligible.

## Tooling

TLC from `vendor/tla2tools-v1.8.0.jar`, or `$TLA2TOOLS_JAR`, or a
`tla2tools.jar` dropped next to the scripts. Java 11 or later.
