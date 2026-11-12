--------------------------- MODULE FlexiblePaxos ---------------------------
(***************************************************************************)
(* Flexible Multi-Paxos, as implemented by `src/peace_core.erl`.           *)
(*                                                                         *)
(* Flexible Paxos weakens the quorum requirement of Paxos. Flexible Paxos  *)
(* is "revision A" of Howard's thesis (UCAM-CL-TR-935, in docs/; chapter   *)
(* 4, section 4.1). Section numbers in this module refer to the thesis.    *)
(* Paxos uses one quorum system for both phases and requires any two       *)
(* quorums to intersect. Flexible Paxos uses two quorum systems:           *)
(*                                                                         *)
(*   - Quorum1 is the set of phase-one quorums. A phase-one quorum must    *)
(*     promise before a proposer may propose.                              *)
(*   - Quorum2 is the set of phase-two quorums. A phase-two quorum must    *)
(*     accept before a value is decided.                                   *)
(*                                                                         *)
(* Flexible Paxos requires only that every phase-one quorum intersects     *)
(* every phase-two quorum (equation 4.4). Two phase-two quorums do not     *)
(* need to intersect. Two phase-one quorums do not need to intersect. The  *)
(* epochs of the thesis are the epochs of this module. This module does    *)
(* NOT assume the intersection. The intersection is a property of the      *)
(* constants. A config can therefore violate the intersection, and TLC     *)
(* then finds the disagreement (FPaxosUnsafeQuorums.cfg).                  *)
(*                                                                         *)
(* What is modelled                                                        *)
(*   - Epochs, promises, and per-index accepted (epoch, value) pairs.      *)
(*   - Phase one covers the whole log at once. A promise carries every     *)
(*     proposal the acceptor holds. In peace, the `promise` message        *)
(*     carries the log suffix of the acceptor in the same way.             *)
(*   - Phase two runs per index. The proposer selects the value reported   *)
(*     at the highest epoch.                                               *)
(*   - Learning. Learning is the optional phase three of section 3.3. An   *)
(*     acceptor that learns that an index is decided keeps the value under *)
(*     the marker epoch `Learned`. `Learned` is higher than every real     *)
(*     epoch. The acceptor reports the value under `Learned` in later      *)
(*     promises. Learning is the only place where peace departs from       *)
(*     textbook Paxos, so learning is the part most worth checking. The    *)
(*     model has the same three routes for learning as the code:           *)
(*       1. The leader counts acceptances from a phase-two quorum          *)
(*          (`LeaderLearn`).                                               *)
(*       2. A follower receives the commit index of its leader and marks   *)
(*          its entries from the epoch of that leader as decided           *)
(*          (`SendCommit`, `FollowerCommit`).                              *)
(*       3. An acceptor copies a decided index from an acceptor that has   *)
(*          it (`CatchUp`).                                                *)
(*   - Stale leaders.  The second route depends on a condition from        *)
(*     section 3.3: an acceptor that is told "decided in epoch e" may      *)
(*     treat its own proposal from epoch e as decided.  A commit index     *)
(*     from the leader of epoch e must therefore mean "the proposal of     *)
(*     epoch e at this index was decided, or equals the decided value".    *)
(*     A leader can be deposed without receiving a message that tells it   *)
(*     so.  Two rules keep its commit index correct in that case.  Both    *)
(*     are controlled by the constant `ConflictStepDown`.                  *)
(*       1. If the leader learns an index with a value different from its  *)
(*          own proposal there, it sends no more commits (`Conflict`,      *)
(*          `SendCommit`).                                                 *)
(*       2. The leader does not propose at an index it already holds as    *)
(*          decided (`Propose`).  Without this rule it could send a commit *)
(*          that covers the index and then propose a different value       *)
(*          there.                                                         *)
(*     peace_core steps down in both cases.  FPaxosNoConflictStepDown.cfg  *)
(*     is the protocol without the two rules.  Rule 2 was added on         *)
(*     2026-11-11; see "Model correction" in README.md.                    *)
(*   - An acceptor that holds a decided index still answers a propose for  *)
(*     that index. The answer does not change what the acceptor holds      *)
(*     (`Accept`, the THEN branch).                                        *)
(*   - Snapshots. An acceptor may drop an index that it knows is decided   *)
(*     (`Snapshot`). peace drops its log below a snapshot in the same way. *)
(*     The acceptor still knows that the index is decided. A later promise *)
(*     from the acceptor does not report what the acceptor accepted at the *)
(*     index. The promise reports only that the index is dropped. If a     *)
(*     proposer treated the missing report as an empty index, a second     *)
(*     value could be decided. A proposer therefore does not propose at an *)
(*     index that any promise reported as dropped (`SnapshotGuard`). In    *)
(*     that case peace abandons the whole campaign and catches up.         *)
(*     FPaxosNoSnapshotGuard.cfg is the protocol without `SnapshotGuard`.  *)
(*   - Message loss, duplication and reordering. `msgs` is a set that only *)
(*     grows. No action is required to receive a message.                  *)
(*                                                                         *)
(*   - NACKs (section 3.1) are not messages in this module. A proposer     *)
(*     that will never get its quorum takes no further steps.              *)
(*                                                                         *)
(* What is not modelled                                                    *)
(*   - Crash and restart. `promised` and `accepted` are durable in peace.  *)
(*     peace writes them through `peace_storage` before it sends any       *)
(*     reply. A restarted acceptor therefore behaves the same as a slow    *)
(*     acceptor. The volatile state (role, commit index, machine state) is *)
(*     not in this model. The DST harness checks that the code persists    *)
(*     state before it replies.                                            *)
(*   - Leader election timing, heartbeats, client replies, the state       *)
(*     machine. In this module any proposer may start any epoch at any     *)
(*     time. This allows every behaviour that election timers allow, and   *)
(*     more.                                                               *)
(*   - Membership change.                                                  *)
(*   - Quorums that vary by epoch (revision B, section 4.2), completing    *)
(*     phase one early (revision C, chapter 5) and quorum-based value      *)
(*     selection (chapter 6). peace implements none of these.              *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Acceptors,      \* set of acceptor ids
    Values,         \* set of proposable values
    MaxEpoch,      \* epochs are 1..MaxEpoch
    MaxIndex,        \* log indexes are 1..MaxIndex
    Quorum1,        \* set of phase-one quorums (subsets of Acceptors)
    Quorum2,        \* set of phase-two quorums (subsets of Acceptors)
    None,           \* the value used when there is no proposal, and the owner
                    \* of an epoch that no acceptor has started
    FenceAccept,    \* TRUE: an acceptor does not accept a propose whose epoch
                    \* is below the epoch the acceptor has promised.
                    \* FALSE is a mutation; see FPaxosNoFence.cfg.
    ConflictStepDown, \* TRUE: the two stale-leader rules apply.  A leader
                    \* that learns an index with a value different from its
                    \* own proposal sends no more commits, and a leader does
                    \* not propose at an index it holds as decided.  FALSE is
                    \* a mutation; see FPaxosNoConflictStepDown.cfg.
    Snapshots,      \* TRUE: acceptors may drop decided indexes.  FALSE keeps
                    \* the state space small in configs that test other
                    \* things.
    SnapshotGuard   \* TRUE: a proposer does not propose at an index that a
                    \* promise reported as dropped.  FALSE is a mutation; see
                    \* FPaxosNoSnapshotGuard.cfg.

VARIABLES
    promised,       \* promised[a]: the highest epoch that a has promised, or
                    \* 0 if a has promised no epoch
    accepted,       \* accepted[a][s]: the proposal that a last accepted for
                    \* index s
    owner,          \* owner[b]: the acceptor that started epoch b, or None.
                    \* A peace epoch is a {Round, ServerId} pair, so an epoch
                    \* has exactly one possible leader.
    msgs,           \* every message ever sent
    dropped         \* dropped[a]: the indexes that a has dropped under a
                    \* snapshot

vars == <<promised, accepted, owner, msgs, dropped>>

Epochs == 1..MaxEpoch
Indexes   == 1..MaxIndex

\* Learned is the marker "epoch" that an acceptor stores for an index that the
\* acceptor knows is decided.  Learned is higher than every real epoch, so
\* selection of the value at the highest epoch always selects a learned value.
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
(* A value is decided at an index when some phase-two quorum has accepted  *)
(* the value in one epoch. An accept message does not contain a value. The *)
(* propose message of the same epoch and index contains the value.         *)
(* `Propose` sends at most one propose message per epoch and index.        *)

DecidedAt(b, s, v) ==
    /\ [type |-> "propose", epoch |-> b, index |-> s, val |-> v] \in msgs
    /\ \E Q \in Quorum2 :
          \A a \in Q : [type |-> "accept", epoch |-> b, index |-> s, acc |-> a] \in msgs

Decided(s, v) == \E b \in Epochs : DecidedAt(b, s, v)

-----------------------------------------------------------------------------
(* In peace, a candidate broadcasts `{prepare, Epoch, From}`. One acceptor *)
(* starts an epoch, and an epoch starts only once.                         *)
Prepare(a, b) ==
    /\ owner[b] = None
    /\ owner' = [owner EXCEPT ![b] = a]
    /\ Send([type |-> "prepare", epoch |-> b])
    /\ UNCHANGED <<promised, accepted, dropped>>

(* In peace, the message is `{promise, Epoch, Entries, Snapshot}`. The     *)
(* epoch must be strictly greater than the epoch the acceptor has          *)
(* promised. An acceptor therefore answers a given epoch at most once, and *)
(* a proposer never receives two different reports from the same acceptor. *)
(* For a dropped index, the promise reports no proposal and reports that   *)
(* the index is dropped.                                                   *)
Promise(a, b) ==
    /\ [type |-> "prepare", epoch |-> b] \in msgs
    /\ b > promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ Send([type |-> "promise", epoch |-> b, acc |-> a,
             votes |-> [s \in Indexes |-> IF s \in dropped[a] THEN NoVote
                                                            ELSE accepted[a][s]],
             dropped |-> dropped[a]])
    /\ UNCHANGED <<accepted, owner, dropped>>

(* In peace, a new leader acts when it has promises from a phase-one       *)
(* quorum. For every index at which any promise reported a proposal, the   *)
(* new leader proposes again the value reported at the highest epoch. At   *)
(* an index where no promise reported a proposal, the new leader may       *)
(* propose any value.                                                      *)
(*                                                                         *)
(* The leader does not propose at an index that the leader already knows   *)
(* is decided. Without this conjunct the commit index is unsound in a case *)
(* that `Conflict` below does not cover:                                   *)
(*   1. A leader is deposed and receives no message that tells it so.      *)
(*   2. The leader learns an index that a later epoch decided.             *)
(*   3. The leader sends a commit index that covers the index. The leader  *)
(*      has proposed nothing at the index.                                 *)
(*   4. The leader then proposes at the index. Phase one permits any       *)
(*      value, because the promises that the leader received reported the  *)
(*      index as empty.                                                    *)
(*   5. A follower that holds that proposal treats the proposal as         *)
(*      decided.                                                           *)
(* The case needs at least five acceptors. TLC finds the case in nineteen  *)
(* states (FPaxosFiveAcceptors.cfg, before this conjunct was added).       *)
(* peace_core never proposes at an index that it holds as decided.         *)
(* peace_core steps down when it learns an index at which it has not       *)
(* proposed. The simulation found the case in the code long before the     *)
(* model was checked for it.                                               *)
(* deposed_leader_steps_down_on_unproposed_index_test tests the case.      *)
Propose(b, s, v) ==
    /\ ~ \E m \in msgs : m.type = "propose" /\ m.epoch = b /\ m.index = s
    /\ owner[b] # None    \* The promises below imply this conjunct.  It makes the next line defined.
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

(* In peace, `{propose, Epoch, Entries, Commit}` is answered by            *)
(* `{accept, ...}`. An acceptor that already knows that the index is       *)
(* decided acknowledges the propose and does not change its entry. There   *)
(* are two reasons:                                                        *)
(*   - The acceptor must never replace a decided entry with an entry from  *)
(*     a lower epoch.                                                      *)
(*   - The acceptor must still answer. Otherwise a leader that has not yet *)
(*     learned that the index is decided could wait forever for a          *)
(*     phase-two quorum.                                                   *)
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

\* Leads(a, b) is the leader role of peace_core.  Acceptor a started epoch b,
\* and acceptor a has promised no epoch above b.  peace_core also steps down
\* when it receives a nack.  That rule removes behaviours and adds none, so
\* the model omits it.
Leads(a, b) == owner[b] = a /\ promised[a] = b

(* In peace, the leader counts `accepted` replies. The leader marks the    *)
(* index as decided when the replies come from a phase-two quorum.         *)
LeaderLearn(b, s) ==
    /\ owner[b] # None
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].epoch # Learned
    /\ \E v \in Values :
          /\ DecidedAt(b, s, v)
          /\ accepted' = [accepted EXCEPT ![owner[b]][s] =
                             [epoch |-> Learned, val |-> v]]
    /\ UNCHANGED <<promised, owner, msgs, dropped>>

\* Conflict(b) holds when the leader of epoch b holds an index as decided with
\* a value different from the value the leader proposed at that index.  Only a
\* later epoch can have decided that value.
Conflict(b) ==
    \E m \in msgs :
        /\ m.type = "propose" /\ m.epoch = b
        /\ accepted[owner[b]][m.index].epoch = Learned
        /\ accepted[owner[b]][m.index].val # m.val

(* In peace, every `propose` message, and therefore every heartbeat,       *)
(* carries the commit index of the leader.                                 *)
SendCommit(b, s) ==
    /\ owner[b] # None
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].epoch = Learned
    /\ ConflictStepDown => ~ Conflict(b)
    /\ Send([type |-> "commit", epoch |-> b, index |-> s])
    /\ UNCHANGED <<promised, accepted, owner, dropped>>

(* In peace, a follower marks as decided each index that the commit index  *)
(* of the leader covers, if the entry of the follower at that index is     *)
(* from the epoch of that leader. An entry from an older epoch may hold a  *)
(* different value. The follower learns such an index through `CatchUp`.   *)
FollowerCommit(a, b, s) ==
    /\ [type |-> "commit", epoch |-> b, index |-> s] \in msgs
    /\ b >= promised[a]
    /\ accepted[a][s].epoch = b
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ accepted' = [accepted EXCEPT ![a][s].epoch = Learned]
    /\ UNCHANGED <<owner, msgs, dropped>>

(* In peace, a server receives decided entries in these ways:              *)
(*   - `{catchup, From}` is answered by `{learned, Entries}`.              *)
(*   - A server that has dropped the entries answers `{catchup, From}`     *)
(*     with `{install, Index, State}`.                                     *)
(*   - A `promise` carries decided entries.                                *)
(* A decided index never changes. This action copies a decided index in    *)
(* one atomic step. The atomic copy therefore loses nothing compared with  *)
(* a copy by message.                                                      *)
CatchUp(a, from, s) ==
    /\ accepted[from][s].epoch = Learned
    /\ accepted[a][s].epoch # Learned
    /\ accepted' = [accepted EXCEPT ![a][s] = accepted[from][s]]
    /\ UNCHANGED <<promised, owner, msgs, dropped>>

(* In peace, a server writes a snapshot and drops its log up to the        *)
(* snapshot. A snapshot covers only decided indexes.                       *)
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

\* At most one value is ever decided per index.  This is the main safety
\* property.
Agreement ==
    \A s \in Indexes, v1, v2 \in Values :
        Decided(s, v1) /\ Decided(s, v2) => v1 = v2

\* This is safe learning as defined in the thesis: "If a participant learns a
\* value, it must learn the decided value."  A peace server applies learned
\* values to its state machine.  The agreement of the state machines
\* therefore depends on this property.
LearnedSound ==
    \A a \in Acceptors, s \in Indexes :
        accepted[a][s].epoch = Learned => Decided(s, accepted[a][s].val)

\* An epoch proposes at most one value per index.
OneValuePerEpoch ==
    \A m1, m2 \in msgs :
        (m1.type = "propose" /\ m2.type = "propose" /\ m1.epoch = m2.epoch /\ m1.index = m2.index)
            => m1.val = m2.val

\* Learned entries are equal across acceptors.  Agreement and LearnedSound
\* imply this property.  It is stated separately because the DST harness
\* checks exactly this property on the running code.
LearnedAgree ==
    \A a1, a2 \in Acceptors, s \in Indexes :
        (accepted[a1][s].epoch = Learned /\ accepted[a2][s].epoch = Learned)
            => accepted[a1][s].val = accepted[a2][s].val

\* Every phase-one quorum intersects every phase-two quorum.  This is the only
\* requirement that Flexible Paxos places on the quorum system.
QuorumIntersection ==
    \A Q1 \in Quorum1, Q2 \in Quorum2 : Q1 \cap Q2 # {}

-----------------------------------------------------------------------------
(* Reachability. Each invariant below must FAIL. Each invariant is the     *)
(* negation of a state that the model must be able to reach. If the model  *)
(* could not reach these states, the invariants above could hold only      *)
(* because the model does very little. See the FPaxosReachable*.cfg        *)
(* configs.                                                                *)

NothingDecided == \A s \in Indexes, v \in Values : ~ Decided(s, v)

NothingLearned == \A a \in Acceptors, s \in Indexes : accepted[a][s].epoch # Learned

\* In every state, some acceptor has not learned some index.  This says that
\* the followers never finish learning.
NotAllLearned == \E a \in Acceptors, s \in Indexes : accepted[a][s].epoch # Learned

\* No acceptor that has dropped an index ever sends a promise.  If this held,
\* SnapshotGuard would have no effect.
NoPromiseAfterSnapshot == \A m \in msgs : m.type = "promise" => m.dropped = {}

\* Conflict(b) never holds for the leader of any epoch b.  If this held, the
\* ConflictStepDown guard would have no effect.
NoConflict == \A b \in Epochs : owner[b] # None => ~ Conflict(b)

\* No value is decided in two epochs.  The model must be able to violate
\* this: after a change of leader, the later epoch proposes a value that an
\* earlier epoch decided, and decides it again.
NoRecovery ==
    \A s \in Indexes, v \in Values, b1, b2 \in Epochs :
        ~ (b1 < b2 /\ DecidedAt(b1, s, v) /\ DecidedAt(b2, s, v))

=============================================================================
