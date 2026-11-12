--------------------------- MODULE FlexiblePaxos ---------------------------
(***************************************************************************)
(* Flexible Multi-Paxos, as implemented by `src/peace_core.erl`.           *)
(*                                                                         *)
(* Flexible Paxos weakens Paxos's quorum requirement.  It is "revision A"  *)
(* of Howard's thesis (UCAM-CL-TR-935, in docs/; chapter 4, section 4.1),  *)
(* and section numbers below refer to the thesis.  Paxos uses one quorum   *)
(* system for both phases and needs any two quorums to intersect.          *)
(* Flexible Paxos uses two:                                                *)
(*                                                                         *)
(*   Quorum1 - who must promise before a proposer may propose (phase one)  *)
(*   Quorum2 - who must accept before a value is decided       (phase two) *)
(*                                                                         *)
(* and needs only that every phase-one quorum intersects every phase-two   *)
(* quorum (equation 4.4).  Two phase-two quorums need not intersect, and   *)
(* neither need two phase-one quorums.  The thesis's epochs are epochs     *)
(* here.  This module does NOT assume the intersection: it is              *)
(* a property of the constants, so that a config can violate it and show   *)
(* TLC finding the disagreement (FPaxosUnsafeQuorums.cfg).                 *)
(*                                                                         *)
(* What is modelled                                                        *)
(*   - Epochs, promises, and per-index accepted (epoch, value) pairs.      *)
(*   - Phase one over the whole log at once: a promise carries every proposal the *)
(*     acceptor holds, as peace's `promise` carries its log suffix.        *)
(*   - Phase two per index, value selection by highest reported epoch.     *)
(*   - Learning, the optional phase three of section 3.3: an acceptor      *)
(*     that learns an index is decided keeps the value under the marker    *)
(*     epoch `Learned`, above every real epoch, and reports it that        *)
(*     way in later promises.  It is the one place                         *)
(*     peace departs from textbook Paxos, so it is the part most worth     *)
(*     checking, and it is modelled the way the code does it, by three     *)
(*     routes: a leader counts a phase-two quorum (`LeaderLearn`), a       *)
(*     follower trusts its leader's commit index (`SendCommit`,            *)
(*     `FollowerCommit`), and anybody copies a decided index from somebody *)
(*     who has it (`CatchUp`).                                             *)
(*   - The hazard in the second route.  A follower marks its own entry     *)
(*     decided when the entry is from its leader's epoch and the leader    *)
(*     says the index is committed.  Section 3.3 states the condition:     *)
(*     "decided in epoch e" lets an acceptor holding a proposal from e     *)
(*     conclude it is decided, where e is the epoch the value was decided  *)
(*     in.  So it is sound only while "committed" means "my proposal was   *)
(*     decided, or agrees with what was".  A deposed leader that has not   *)
(*     heard it was deposed can catch an index up from the new regime, find*)
(*     a different value there, and would then be advertising a commit     *)
(*     index that covers an index where its own proposal lost.  peace steps*)
(*     down the moment it sees that (`ConflictStepDown`);                  *)
(*     FPaxosNoConflictStepDown.cfg is the protocol without it.            *)
(*   - An acceptor holding a decided index still answers a propose for it  *)
(*     without changing what it holds (`Accept`, second disjunct).         *)
(*   - Snapshots.  An acceptor may drop an index it knows is decided, as   *)
(*     peace drops its log below a snapshot (`Snapshot`).  It still knows  *)
(*     the index is decided, but its promise no longer says what it accepted *)
(*     there, only that the index is dropped.  A proposer that took silence*)
(*     to mean "free" could have a second value decided, so it does not    *)
(*     propose in an index any promise reported dropped (`SnapshotGuard`); *)
(*     peace abandons the whole campaign and catches up.                   *)
(*     FPaxosNoSnapshotGuard.cfg is the protocol without it.               *)
(*   - Message loss, duplication and reordering: `msgs` is a set that      *)
(*     only grows and nothing is ever obliged to be received.              *)
(*                                                                         *)
(*   - NACKs (section 3.1) are not messages here: a proposer that will     *)
(*     never get its quorum is one that simply takes no further steps.     *)
(*                                                                         *)
(* What is not                                                             *)
(*   - Crash and restart.  `promised` and `accepted` are durable in        *)
(*     peace (written through `peace_storage` before any reply is sent),   *)
(*     so a restarted acceptor is indistinguishable from a slow one.  The  *)
(*     volatile state (role, commit index, machine state) is not in this   *)
(*     model.  The DST harness covers the claim that the code really does  *)
(*     persist before it replies.                                          *)
(*   - Leader election timing, heartbeats, client replies, the state       *)
(*     machine.  Any proposer may start any epoch at any time here, which  *)
(*     is a superset of what election timers allow.                        *)
(*   - Membership change.                                                  *)
(*   - Quorums that vary by epoch (revision B, section 4.2), completing    *)
(*     phase one early (revision C, chapter 5) and quorum-based value      *)
(*     selection (chapter 6).  peace implements none of them.              *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Acceptors,      \* set of acceptor ids
    Values,         \* set of proposable values
    MaxEpoch,      \* epochs are 1..MaxEpoch
    MaxIndex,        \* log indexes are 1..MaxIndex
    Quorum1,        \* set of phase-one quorums (subsets of Acceptors)
    Quorum2,        \* set of phase-two quorums (subsets of Acceptors)
    None,           \* the value of no proposal, and the owner of an unused epoch
    FenceAccept,    \* TRUE: an acceptor refuses a propose below its promise.
                    \* FALSE is a mutation; see FPaxosNoFence.cfg.
    ConflictStepDown, \* TRUE: a leader that learns an index was decided against
                    \* its own proposal stops advertising commits.  FALSE is
                    \* a mutation; see FPaxosNoConflictStepDown.cfg.
    Snapshots,      \* TRUE: acceptors may drop decided indexes.  FALSE keeps
                    \* the state space of configs that are about other things.
    SnapshotGuard   \* TRUE: a proposer does not propose in an index a promise
                    \* reported dropped.  FALSE is a mutation; see
                    \* FPaxosNoSnapshotGuard.cfg.

VARIABLES
    promised,       \* promised[a]: highest epoch a has promised, 0 if none
    accepted,       \* accepted[a][s]: the proposal a last accepted for index s
    owner,          \* owner[b]: the acceptor that started epoch b, or None.
                    \* peace epochs are {Round, ServerId} pairs, so an epoch
                    \* has exactly one possible leader.
    msgs,           \* every message ever sent
    dropped         \* dropped[a]: the indexes a has dropped under a snapshot

vars == <<promised, accepted, owner, msgs, dropped>>

Epochs == 1..MaxEpoch
Indexes   == 1..MaxIndex

\* The marker "epoch" of an index an acceptor knows to be decided.  Above every
\* real epoch, so highest-epoch value selection always prefers it.
Learned == MaxEpoch + 1

NoVote == [epoch |-> -1, val |-> None]

Vote == [epoch : Epochs \cup {Learned}, val : Values] \cup {NoVote}

Message ==
         [type : {"prepare"}, epoch : Epochs]
    \cup [type : {"promise"}, epoch : Epochs, acc : Acceptors, votes : [Indexes -> Vote],
          dropped : SUBSET Indexes]
    \cup [type : {"propose"}, epoch : Epochs, index : Indexes, val : Values]
    \cup [type : {"accept"}, epoch : Epochs, index : Indexes, acc : Acceptors]
    \cup [type : {"commit"}, epoch : Epochs, index : Indexes]

TypeOK ==
    /\ promised \in [Acceptors -> 0..MaxEpoch]
    /\ accepted \in [Acceptors -> [Indexes -> Vote]]
    /\ owner \in [Epochs -> Acceptors \cup {None}]
    /\ msgs \subseteq Message
    /\ dropped \in [Acceptors -> SUBSET Indexes]

Init ==
    /\ promised = [a \in Acceptors |-> 0]
    /\ accepted = [a \in Acceptors |-> [s \in Indexes |-> NoVote]]
    /\ owner = [b \in Epochs |-> None]
    /\ msgs = {}
    /\ dropped = [a \in Acceptors |-> {}]

Send(m) == msgs' = msgs \cup {m}

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

-----------------------------------------------------------------------------
(* A value is decided at an index once some phase-two quorum has accepted it in *)
(* one epoch.  An accept names no value; the propose of the same epoch and index *)
(* does, and there is at most one of those (`Propose`).                    *)

DecidedAt(b, s, v) ==
    /\ [type |-> "propose", epoch |-> b, index |-> s, val |-> v] \in msgs
    /\ \E Q \in Quorum2 :
          \A a \in Q : [type |-> "accept", epoch |-> b, index |-> s, acc |-> a] \in msgs

Decided(s, v) == \E b \in Epochs : DecidedAt(b, s, v)

-----------------------------------------------------------------------------
(* peace: a candidate broadcasts `{prepare, Epoch, From}`.  An epoch is    *)
(* started once, by one acceptor.                                          *)
Prepare(a, b) ==
    /\ owner[b] = None
    /\ owner' = [owner EXCEPT ![b] = a]
    /\ Send([type |-> "prepare", epoch |-> b])
    /\ UNCHANGED <<promised, accepted, dropped>>

(* peace: `{promise, Epoch, Entries, Snapshot}`.  Strictly greater, so an  *)
(* acceptor answers a given epoch at most once and a proposer never sees   *)
(* two different reports from the same acceptor.  Of a dropped index it    *)
(* reports no proposal, and that it is dropped.                            *)
Promise(a, b) ==
    /\ [type |-> "prepare", epoch |-> b] \in msgs
    /\ b > promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ Send([type |-> "promise", epoch |-> b, acc |-> a,
             votes |-> [s \in Indexes |-> IF s \in dropped[a] THEN NoVote
                                                            ELSE accepted[a][s]],
             dropped |-> dropped[a]])
    /\ UNCHANGED <<accepted, owner, dropped>>

(* peace: on a phase-one quorum of promises the new leader re-proposes, for*)
(* every index anybody reported, the value reported at the highest epoch,  *)
(* and is free to propose anything where nobody reported a proposal.       *)
(*                                                                         *)
(* It does not propose in an index it already knows is decided.  Without   *)
(* that the commit index is unsound in a way `Conflict` below does not     *)
(* cover: a leader that has been deposed without hearing of it can learn   *)
(* an index a later epoch decided, advertise a commit index over it having *)
(* proposed nothing there, and only then propose there, freely, since its  *)
(* own phase one saw the index empty.  A follower holding that proposal    *)
(* takes it as decided.  Five acceptors are the fewest that can do it, and *)
(* TLC finds it in nineteen states (FPaxosFiveAcceptors.cfg, before this   *)
(* conjunct).  peace_core never proposes in an index it holds decided, and *)
(* steps down on learning one it has not proposed in: the simulation found *)
(* that case in the code long before the model was asked about it, and it  *)
(* is deposed_leader_steps_down_on_unproposed_index_test.                  *)
Propose(b, s, v) ==
    /\ ~ \E m \in msgs : m.type = "propose" /\ m.epoch = b /\ m.index = s
    /\ owner[b] # None    \* implied by the promises below; here so the next line is defined
    /\ ConflictStepDown => accepted[owner[b]][s].epoch # Learned
    /\ \E Q \in Quorum1 :
          LET reports == {m \in msgs : m.type = "promise" /\ m.epoch = b /\ m.acc \in Q}
              votes   == {m.votes[s] : m \in reports}
          IN  /\ \A a \in Q : \E m \in reports : m.acc = a
              /\ SnapshotGuard => \A m \in reports : s \notin m.dropped
              /\ \/ \A vt \in votes : vt.epoch = -1
                 \/ \E vt \in votes :
                       /\ vt.epoch = Max({w.epoch : w \in votes})
                       /\ vt.val = v
    /\ Send([type |-> "propose", epoch |-> b, index |-> s, val |-> v])
    /\ UNCHANGED <<promised, accepted, owner, dropped>>

(* peace: `{propose, Epoch, Entries, Commit}` answered by `{accept, ...}`. *)
(* An index already known decided is acknowledged and left alone: the      *)
(* acceptor must never replace a decided entry with a lower-epoch one,     *)
(* and it must still answer or a leader that has not yet learned the index *)
(* is decided could wait forever for a phase-two quorum.                   *)
Accept(a, b, s) ==
    /\ \E m \in msgs :
          /\ m.type = "propose" /\ m.epoch = b /\ m.index = s
          /\ FenceAccept => b >= promised[a]
          /\ promised' = [promised EXCEPT ![a] = IF b > @ THEN b ELSE @]
          /\ IF accepted[a][s].epoch = Learned
                THEN UNCHANGED accepted
                ELSE accepted' = [accepted EXCEPT ![a][s] =
                                    [epoch |-> b, val |-> m.val]]
    /\ Send([type |-> "accept", epoch |-> b, index |-> s, acc |-> a])
    /\ UNCHANGED <<owner, dropped>>

-----------------------------------------------------------------------------
(* Learning.                                                               *)

\* peace_core's leader role: it has promised nothing above its own epoch.
\* (It also steps down on a nack; fewer behaviours, not more.)
Leads(a, b) == owner[b] = a /\ promised[a] = b

(* peace: the leader counts `accepted` replies and marks the index decided *)
(* once they form a phase-two quorum.                                      *)
LeaderLearn(b, s) ==
    /\ owner[b] # None
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].epoch # Learned
    /\ \E v \in Values :
          /\ DecidedAt(b, s, v)
          /\ accepted' = [accepted EXCEPT ![owner[b]][s] =
                             [epoch |-> Learned, val |-> v]]
    /\ UNCHANGED <<promised, owner, msgs, dropped>>

\* The leader of b holds an index decided with a value other than the one it
\* proposed there.  Only a later epoch can have decided that value.
Conflict(b) ==
    \E m \in msgs :
        /\ m.type = "propose" /\ m.epoch = b
        /\ accepted[owner[b]][m.index].epoch = Learned
        /\ accepted[owner[b]][m.index].val # m.val

(* peace: every `accept` (and so every heartbeat) carries the leader's     *)
(* commit index.                                                           *)
SendCommit(b, s) ==
    /\ owner[b] # None
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].epoch = Learned
    /\ ConflictStepDown => ~ Conflict(b)
    /\ Send([type |-> "commit", epoch |-> b, index |-> s])
    /\ UNCHANGED <<promised, accepted, owner, dropped>>

(* peace: a follower marks decided each index the leader's commit index    *)
(* covers, provided its own entry there is from that leader's epoch.  An   *)
(* entry from an older epoch may be a different value; that index waits    *)
(* for `CatchUp`.                                                          *)
FollowerCommit(a, b, s) ==
    /\ [type |-> "commit", epoch |-> b, index |-> s] \in msgs
    /\ b >= promised[a]
    /\ accepted[a][s].epoch = b
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ accepted' = [accepted EXCEPT ![a][s].epoch = Learned]
    /\ UNCHANGED <<owner, msgs, dropped>>

(* peace: `{catchup, From}` answered by `{learned, Entries}` or, from a    *)
(* server that has dropped the entries, by `{install, Index, State}`; and  *)
(* decided entries carried in a `promise`.  A decided index never changes, *)
(* so copying it atomically loses nothing against copying it by message.   *)
CatchUp(a, from, s) ==
    /\ accepted[from][s].epoch = Learned
    /\ accepted[a][s].epoch # Learned
    /\ accepted' = [accepted EXCEPT ![a][s] = accepted[from][s]]
    /\ UNCHANGED <<promised, owner, msgs, dropped>>

(* peace: a server writes a snapshot and drops its log up to there.  Only  *)
(* decided indexes are ever under a snapshot.                              *)
Snapshot(a, s) ==
    /\ Snapshots
    /\ accepted[a][s].epoch = Learned
    /\ s \notin dropped[a]
    /\ dropped' = [dropped EXCEPT ![a] = @ \cup {s}]
    /\ UNCHANGED <<promised, accepted, owner, msgs>>

Next ==
    \/ \E a \in Acceptors, b \in Epochs : Prepare(a, b)
    \/ \E a \in Acceptors, b \in Epochs : Promise(a, b)
    \/ \E b \in Epochs, s \in Indexes, v \in Values : Propose(b, s, v)
    \/ \E a \in Acceptors, b \in Epochs, s \in Indexes : Accept(a, b, s)
    \/ \E b \in Epochs, s \in Indexes : LeaderLearn(b, s)
    \/ \E b \in Epochs, s \in Indexes : SendCommit(b, s)
    \/ \E a \in Acceptors, b \in Epochs, s \in Indexes : FollowerCommit(a, b, s)
    \/ \E a, from \in Acceptors, s \in Indexes : CatchUp(a, from, s)
    \/ \E a \in Acceptors, s \in Indexes : Snapshot(a, s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety.                                                                 *)

\* At most one value is ever decided per index.  The whole point.
Agreement ==
    \A s \in Indexes, v1, v2 \in Values :
        Decided(s, v1) /\ Decided(s, v2) => v1 = v2

\* The thesis's safe learning: "If a participant learns a value, it must
\* learn the decided value."  This is what
\* a peace server applies to its state machine, so it is the property the
\* state machines' agreement actually rests on.
LearnedSound ==
    \A a \in Acceptors, s \in Indexes :
        accepted[a][s].epoch = Learned => Decided(s, accepted[a][s].val)

\* An epoch proposes at most one value per index.
OneValuePerEpoch ==
    \A m1, m2 \in msgs :
        (m1.type = "propose" /\ m2.type = "propose" /\ m1.epoch = m2.epoch /\ m1.index = m2.index)
            => m1.val = m2.val

\* Learned entries agree across acceptors.  Implied by the two above; stated
\* because it is literally what the DST harness checks on the running code.
LearnedAgree ==
    \A a1, a2 \in Acceptors, s \in Indexes :
        (accepted[a1][s].epoch = Learned /\ accepted[a2][s].epoch = Learned)
            => accepted[a1][s].val = accepted[a2][s].val

\* What Flexible Paxos asks of the quorum system, and all it asks.
QuorumIntersection ==
    \A Q1 \in Quorum1, Q2 \in Quorum2 : Q1 \cap Q2 # {}

-----------------------------------------------------------------------------
(* Reachability.  These are meant to FAIL: each is the negation of a state *)
(* the model has to be able to reach for the invariants above to mean      *)
(* anything.  See FPaxosReachable.cfg.                                     *)

NothingDecided == \A s \in Indexes, v \in Values : ~ Decided(s, v)

NothingLearned == \A a \in Acceptors, s \in Indexes : accepted[a][s].epoch # Learned

\* Never does every acceptor know every index: followers never finish learning.
NotAllLearned == \E a \in Acceptors, s \in Indexes : accepted[a][s].epoch # Learned

\* No epoch is ever promised by an acceptor that has dropped an index, i.e.
\* the SnapshotGuard guards nothing.
NoPromiseAfterSnapshot == \A m \in msgs : m.type = "promise" => m.dropped = {}

\* A leader never finds itself contradicted, i.e. the ConflictStepDown guard
\* guards nothing.
NoConflict == \A b \in Epochs : owner[b] # None => ~ Conflict(b)

\* No value decided in one epoch is ever re-proposed by a later one, i.e. a
\* leader change never has to recover anything.
NoRecovery ==
    \A s \in Indexes, v \in Values, b1, b2 \in Epochs :
        ~ (b1 < b2 /\ DecidedAt(b1, s, v) /\ DecidedAt(b2, s, v))

=============================================================================
