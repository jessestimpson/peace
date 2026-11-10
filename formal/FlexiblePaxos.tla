--------------------------- MODULE FlexiblePaxos ---------------------------
(***************************************************************************)
(* Multi-decree Flexible Paxos, as implemented by `src/peace_core.erl`.    *)
(*                                                                         *)
(* Flexible Paxos weakens Paxos's quorum requirement.  It is "revision A"  *)
(* of Howard's thesis (UCAM-CL-TR-935, in docs/; chapter 4, section 4.1),  *)
(* and section numbers below refer to the thesis.  Paxos uses one quorum   *)
(* system for both phases and needs any two quorums to intersect.          *)
(* Flexible Paxos uses two:                                                *)
(*                                                                         *)
(*   Quorum1 - who must promise before a proposer may propose (phase 1)    *)
(*   Quorum2 - who must accept before a value is chosen       (phase 2)    *)
(*                                                                         *)
(* and needs only that every phase-1 quorum intersects every phase-2       *)
(* quorum (equation 4.4).  Two phase-2 quorums need not intersect, and     *)
(* neither need two phase-1 quorums.  The thesis's epochs are ballots      *)
(* here.  This module does NOT assume the intersection: it is              *)
(* a property of the constants, so that a config can violate it and show   *)
(* TLC finding the disagreement (FPaxosUnsafeQuorums.cfg).                 *)
(*                                                                         *)
(* What is modelled                                                        *)
(*   - Ballots, promises, and per-slot accepted (ballot, value) pairs.     *)
(*   - Phase 1 over the whole log at once: a 1b carries every vote the     *)
(*     acceptor holds, as peace's `promise` carries its log suffix.        *)
(*   - Phase 2 per slot, value selection by highest reported ballot.       *)
(*   - Learning, the optional phase three of section 3.3: an acceptor      *)
(*     that learns a slot is chosen keeps the value under the marker       *)
(*     ballot `Decided`, above every real ballot, and reports it that      *)
(*     way in later 1b messages.  It is the one place                      *)
(*     peace departs from textbook Paxos, so it is the part most worth     *)
(*     checking, and it is modelled the way the code does it, by three     *)
(*     routes: a leader counts a phase-2 quorum (`LeaderDecide`), a        *)
(*     follower trusts its leader's commit index (`SendCommit`,            *)
(*     `FollowerCommit`), and anybody copies a decided slot from somebody  *)
(*     who has it (`CatchUp`).                                             *)
(*   - The hazard in the second route.  A follower marks its own entry     *)
(*     decided when the entry is from its leader's ballot and the leader   *)
(*     says the slot is committed.  Section 3.3 states the condition:      *)
(*     "decided in epoch e" lets an acceptor holding a proposal from e     *)
(*     conclude it is decided, where e is the epoch the value was decided  *)
(*     in.  So it is sound only while "committed" means "my proposal was   *)
(*     chosen, or agrees with what was".  A deposed leader that has not    *)
(*     heard it was deposed can catch a slot up from the new regime, find  *)
(*     a different value there, and would then be advertising a commit     *)
(*     index that covers a slot where its own proposal lost.  peace steps  *)
(*     down the moment it sees that (`ConflictStepDown`);                  *)
(*     FPaxosNoConflictStepDown.cfg is the protocol without it.            *)
(*   - An acceptor holding a decided slot still answers a 2a for it        *)
(*     without changing what it holds (`Phase2b`, second disjunct).        *)
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
(*     machine.  Any proposer may start any ballot at any time here, which *)
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
    MaxBallot,      \* ballots are 1..MaxBallot
    MaxSlot,        \* log slots are 1..MaxSlot
    Quorum1,        \* set of phase-1 quorums (subsets of Acceptors)
    Quorum2,        \* set of phase-2 quorums (subsets of Acceptors)
    None,           \* the value of an empty vote, and the owner of an unused ballot
    FenceAccept,    \* TRUE: an acceptor refuses a 2a below its promise.
                    \* FALSE is a mutation; see FPaxosNoFence.cfg.
    ConflictStepDown \* TRUE: a leader that learns a slot was decided against
                    \* its own proposal stops advertising commits.  FALSE is
                    \* a mutation; see FPaxosNoConflictStepDown.cfg.

VARIABLES
    promised,       \* promised[a]: highest ballot a has promised, 0 if none
    accepted,       \* accepted[a][s]: a's vote for slot s
    owner,          \* owner[b]: the acceptor that started ballot b, or None.
                    \* peace ballots are {Round, ServerId} pairs, so a ballot
                    \* has exactly one possible leader.
    msgs            \* every message ever sent

vars == <<promised, accepted, owner, msgs>>

Ballots == 1..MaxBallot
Slots   == 1..MaxSlot

\* The marker "ballot" of a slot an acceptor knows to be chosen.  Above every
\* real ballot, so highest-ballot value selection always prefers it.
Decided == MaxBallot + 1

NoVote == [bal |-> -1, val |-> None]

Vote == [bal : Ballots \cup {Decided}, val : Values] \cup {NoVote}

Message ==
         [type : {"1a"}, bal : Ballots]
    \cup [type : {"1b"}, bal : Ballots, acc : Acceptors, votes : [Slots -> Vote]]
    \cup [type : {"2a"}, bal : Ballots, slot : Slots, val : Values]
    \cup [type : {"2b"}, bal : Ballots, slot : Slots, acc : Acceptors]
    \cup [type : {"commit"}, bal : Ballots, slot : Slots]

TypeOK ==
    /\ promised \in [Acceptors -> 0..MaxBallot]
    /\ accepted \in [Acceptors -> [Slots -> Vote]]
    /\ owner \in [Ballots -> Acceptors \cup {None}]
    /\ msgs \subseteq Message

Init ==
    /\ promised = [a \in Acceptors |-> 0]
    /\ accepted = [a \in Acceptors |-> [s \in Slots |-> NoVote]]
    /\ owner = [b \in Ballots |-> None]
    /\ msgs = {}

Send(m) == msgs' = msgs \cup {m}

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

-----------------------------------------------------------------------------
(* A value is chosen at a slot once some phase-2 quorum has accepted it in  *)
(* one ballot.  A 2b names no value; the 2a of the same ballot and slot     *)
(* does, and there is at most one of those (`Phase2a`).                     *)

ChosenAt(b, s, v) ==
    /\ [type |-> "2a", bal |-> b, slot |-> s, val |-> v] \in msgs
    /\ \E Q \in Quorum2 :
          \A a \in Q : [type |-> "2b", bal |-> b, slot |-> s, acc |-> a] \in msgs

Chosen(s, v) == \E b \in Ballots : ChosenAt(b, s, v)

-----------------------------------------------------------------------------
(* peace: a candidate broadcasts `{prepare, Ballot, From}`.  A ballot is   *)
(* started once, by one acceptor.                                           *)
Phase1a(a, b) ==
    /\ owner[b] = None
    /\ owner' = [owner EXCEPT ![b] = a]
    /\ Send([type |-> "1a", bal |-> b])
    /\ UNCHANGED <<promised, accepted>>

(* peace: `{promise, Ballot, Entries}`.  Strictly greater, so an acceptor   *)
(* answers a given ballot at most once and a proposer never sees two        *)
(* different reports from the same acceptor.                                *)
Phase1b(a, b) ==
    /\ [type |-> "1a", bal |-> b] \in msgs
    /\ b > promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ Send([type |-> "1b", bal |-> b, acc |-> a, votes |-> accepted[a]])
    /\ UNCHANGED <<accepted, owner>>

(* peace: on a phase-1 quorum of promises the new leader re-proposes, for   *)
(* every slot anybody reported, the value reported at the highest ballot,   *)
(* and is free to propose anything where nobody reported a vote.            *)
Phase2a(b, s, v) ==
    /\ ~ \E m \in msgs : m.type = "2a" /\ m.bal = b /\ m.slot = s
    /\ \E Q \in Quorum1 :
          LET reports == {m \in msgs : m.type = "1b" /\ m.bal = b /\ m.acc \in Q}
              votes   == {m.votes[s] : m \in reports}
          IN  /\ \A a \in Q : \E m \in reports : m.acc = a
              /\ \/ \A vt \in votes : vt.bal = -1
                 \/ \E vt \in votes :
                       /\ vt.bal = Max({w.bal : w \in votes})
                       /\ vt.val = v
    /\ Send([type |-> "2a", bal |-> b, slot |-> s, val |-> v])
    /\ UNCHANGED <<promised, accepted, owner>>

(* peace: `{accept, Ballot, Entries, Commit}` answered by `{accepted, ...}`.*)
(* A slot already known decided is acknowledged and left alone: the         *)
(* acceptor must never replace a decided entry with a lower-ballot one,     *)
(* and it must still answer or a leader that has not yet learned the slot   *)
(* is decided could wait forever for a phase-2 quorum.                      *)
Phase2b(a, b, s) ==
    /\ \E m \in msgs :
          /\ m.type = "2a" /\ m.bal = b /\ m.slot = s
          /\ FenceAccept => b >= promised[a]
          /\ promised' = [promised EXCEPT ![a] = IF b > @ THEN b ELSE @]
          /\ IF accepted[a][s].bal = Decided
                THEN UNCHANGED accepted
                ELSE accepted' = [accepted EXCEPT ![a][s] =
                                    [bal |-> b, val |-> m.val]]
    /\ Send([type |-> "2b", bal |-> b, slot |-> s, acc |-> a])
    /\ UNCHANGED owner

-----------------------------------------------------------------------------
(* Learning.                                                                *)

\* peace_core's leader role: it has promised nothing above its own ballot.
\* (It also steps down on a nack; fewer behaviours, not more.)
Leads(a, b) == owner[b] = a /\ promised[a] = b

(* peace: the leader counts `accepted` replies and marks the slot decided   *)
(* once they form a phase-2 quorum.                                         *)
LeaderDecide(b, s) ==
    /\ owner[b] # None
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].bal # Decided
    /\ \E v \in Values :
          /\ ChosenAt(b, s, v)
          /\ accepted' = [accepted EXCEPT ![owner[b]][s] =
                             [bal |-> Decided, val |-> v]]
    /\ UNCHANGED <<promised, owner, msgs>>

\* The leader of b holds a slot decided with a value other than the one it
\* proposed there.  Only a later ballot can have chosen that value.
Conflict(b) ==
    \E m \in msgs :
        /\ m.type = "2a" /\ m.bal = b
        /\ accepted[owner[b]][m.slot].bal = Decided
        /\ accepted[owner[b]][m.slot].val # m.val

(* peace: every `accept` (and so every heartbeat) carries the leader's      *)
(* commit index.                                                            *)
SendCommit(b, s) ==
    /\ owner[b] # None
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].bal = Decided
    /\ ConflictStepDown => ~ Conflict(b)
    /\ Send([type |-> "commit", bal |-> b, slot |-> s])
    /\ UNCHANGED <<promised, accepted, owner>>

(* peace: a follower marks decided each slot the leader's commit index      *)
(* covers, provided its own entry there is from that leader's ballot.  An   *)
(* entry from an older ballot may be a different value; that slot waits     *)
(* for `CatchUp`.                                                           *)
FollowerCommit(a, b, s) ==
    /\ [type |-> "commit", bal |-> b, slot |-> s] \in msgs
    /\ b >= promised[a]
    /\ accepted[a][s].bal = b
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ accepted' = [accepted EXCEPT ![a][s].bal = Decided]
    /\ UNCHANGED <<owner, msgs>>

(* peace: `{catchup, From}` answered by `{learned, Entries}`, and decided   *)
(* entries carried in a `promise`.  A decided slot never changes, so        *)
(* copying it atomically loses nothing against copying it by message.       *)
CatchUp(a, from, s) ==
    /\ accepted[from][s].bal = Decided
    /\ accepted[a][s].bal # Decided
    /\ accepted' = [accepted EXCEPT ![a][s] = accepted[from][s]]
    /\ UNCHANGED <<promised, owner, msgs>>

Next ==
    \/ \E a \in Acceptors, b \in Ballots : Phase1a(a, b)
    \/ \E a \in Acceptors, b \in Ballots : Phase1b(a, b)
    \/ \E b \in Ballots, s \in Slots, v \in Values : Phase2a(b, s, v)
    \/ \E a \in Acceptors, b \in Ballots, s \in Slots : Phase2b(a, b, s)
    \/ \E b \in Ballots, s \in Slots : LeaderDecide(b, s)
    \/ \E b \in Ballots, s \in Slots : SendCommit(b, s)
    \/ \E a \in Acceptors, b \in Ballots, s \in Slots : FollowerCommit(a, b, s)
    \/ \E a, from \in Acceptors, s \in Slots : CatchUp(a, from, s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety.                                                                  *)

\* At most one value is ever chosen per slot.  The whole point.
Agreement ==
    \A s \in Slots, v1, v2 \in Values :
        Chosen(s, v1) /\ Chosen(s, v2) => v1 = v2

\* Whatever an acceptor holds as decided is the chosen value.  This is what
\* a peace server applies to its state machine, so it is the property the
\* state machines' agreement actually rests on.
DecidedSound ==
    \A a \in Acceptors, s \in Slots :
        accepted[a][s].bal = Decided => Chosen(s, accepted[a][s].val)

\* A ballot proposes at most one value per slot.
OneValuePerBallot ==
    \A m1, m2 \in msgs :
        (m1.type = "2a" /\ m2.type = "2a" /\ m1.bal = m2.bal /\ m1.slot = m2.slot)
            => m1.val = m2.val

\* Decided entries agree across acceptors.  Implied by the two above; stated
\* because it is literally what the DST harness checks on the running code.
DecidedAgree ==
    \A a1, a2 \in Acceptors, s \in Slots :
        (accepted[a1][s].bal = Decided /\ accepted[a2][s].bal = Decided)
            => accepted[a1][s].val = accepted[a2][s].val

\* What Flexible Paxos asks of the quorum system, and all it asks.
QuorumIntersection ==
    \A Q1 \in Quorum1, Q2 \in Quorum2 : Q1 \cap Q2 # {}

-----------------------------------------------------------------------------
(* Reachability.  These are meant to FAIL: each is the negation of a state  *)
(* the model has to be able to reach for the invariants above to mean       *)
(* anything.  See FPaxosReachable.cfg.                                      *)

NothingChosen == \A s \in Slots, v \in Values : ~ Chosen(s, v)

NothingLearned == \A a \in Acceptors, s \in Slots : accepted[a][s].bal # Decided

\* Never does every acceptor know every slot: followers never finish learning.
NotAllLearned == \E a \in Acceptors, s \in Slots : accepted[a][s].bal # Decided

\* A leader never finds itself contradicted, i.e. the ConflictStepDown guard
\* guards nothing.
NoConflict == \A b \in Ballots : owner[b] # None => ~ Conflict(b)

\* No value chosen in one ballot is ever re-proposed by a later one, i.e. a
\* leader change never has to recover anything.
NoRecovery ==
    \A s \in Slots, v \in Values, b1, b2 \in Ballots :
        ~ (b1 < b2 /\ ChosenAt(b1, s, v) /\ ChosenAt(b2, s, v))

=============================================================================
