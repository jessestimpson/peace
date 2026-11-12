-------------------------- MODULE FlexiblePaxosInd --------------------------
(***************************************************************************)
(* This module restates FlexiblePaxos.tla in a form for which an inductive *)
(* invariant can be checked. This module also defines the inductive        *)
(* invariant.                                                              *)
(*                                                                         *)
(* TLC checks FlexiblePaxos by visiting every reachable state. Its time    *)
(* grows quickly with the number of epochs and indexes: two epochs and     *)
(* two indexes take 59 minutes. An inductive invariant is checked one      *)
(* step at a time:                                                         *)
(*   - The invariant holds in the initial state.                           *)
(*   - Every state that satisfies the invariant, reachable or not, steps   *)
(*     only to states that satisfy the invariant.                          *)
(* The invariant then holds in every reachable state of every behaviour,   *)
(* of any length. The cost of the check does not grow with the length of   *)
(* behaviours. Apalache checks the three implications symbolically; see    *)
(* check_ind.sh.                                                           *)
(*                                                                         *)
(* Limitations                                                             *)
(*   - The constants are fixed for each check. This is not a proof for     *)
(*     every number of acceptors, epochs and indexes. That would require a *)
(*     proof system (TLAPS). The guarantee is the same as the guarantee    *)
(*     that TLC gives, for bounds that TLC cannot reach.                   *)
(*                                                                         *)
(* Differences from FlexiblePaxos.tla                                      *)
(*   - This module has no set of messages. Apalache has no type for a set  *)
(*     of records with different fields. A symbolic "any set of messages"  *)
(*     is also far larger than the set of messages the protocol can send.  *)
(*     Each kind of message has its own variable. The shape of each        *)
(*     variable follows from the messages that can exist: one promise per  *)
(*     acceptor and epoch, and one proposal per epoch and index. A prepare *)
(*     is represented by the fact that the epoch has an owner.             *)
(*   - None is the string "none".                                          *)
(*   - Every safeguard is always enabled, except `LearnedGuard`, which is  *)
(*     a constant. The other mutations are checked on FlexiblePaxos.tla.   *)
(*                                                                         *)
(* TLC checks that this module is the same protocol as FlexiblePaxos.      *)
(* FPaxosIndRefines.tla rebuilds the message set of FlexiblePaxos from the *)
(* variables of this module. TLC checks that every behaviour of this spec, *)
(* under that mapping, is a behaviour of FlexiblePaxos.                    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    \* @type: Set(Str);
    Acceptors,
    \* @type: Set(Str);
    Values,
    \* @type: Int;
    MaxEpoch,
    \* @type: Int;
    MaxIndex,
    \* @type: Set(Set(Str));
    Quorum1,
    \* @type: Set(Set(Str));
    Quorum2,
    \* TRUE: a leader does not propose at an index that it holds as decided.
    \* FALSE is the model as it was before 2026-11-11.  FALSE is kept so that
    \* check_ind.sh can show that the invariant is not inductive without the
    \* guard.
    \* @type: Bool;
    LearnedGuard

VARIABLES
    \* @type: Str -> Int;
    promised,
    \* @type: Str -> (Int -> { epoch: Int, val: Str });
    accepted,
    \* @type: Int -> Str;
    owner,
    \* @type: Str -> Set(Int);
    dropped,
    \* pSent is the set of promises sent, each as <<acceptor, epoch>>.  pVotes
    \* and pDrop hold what each promise reported.
    \* @type: Set(<<Str, Int>>);
    pSent,
    \* @type: <<Str, Int>> -> (Int -> { epoch: Int, val: Str });
    pVotes,
    \* @type: <<Str, Int>> -> Set(Int);
    pDrop,
    \* proposal[<<b, s>>]: the value that epoch b proposed at index s, or
    \* "none" if epoch b has proposed no value at index s.
    \* @type: <<Int, Int>> -> Str;
    proposal,
    \* accs is the set of accepts sent, each as <<acceptor, epoch, index>>.
    \* @type: Set(<<Str, Int, Int>>);
    accs,
    \* commits is the set of commits sent, each as <<epoch, index>>.
    \* @type: Set(<<Int, Int>>);
    commits

vars == <<promised, accepted, owner, dropped, pSent, pVotes, pDrop, proposal, accs, commits>>

Epochs  == 1..MaxEpoch
Indexes == 1..MaxIndex
Learned == MaxEpoch + 1

NoVote == [epoch |-> -1, val |-> "none"]
Vote   == [epoch : Epochs \cup {Learned}, val : Values] \cup {NoVote}

TypeOK ==
    /\ promised \in [Acceptors -> 0..MaxEpoch]
    /\ accepted \in [Acceptors -> [Indexes -> Vote]]
    /\ owner \in [Epochs -> Acceptors \cup {"none"}]
    /\ dropped \in [Acceptors -> SUBSET Indexes]
    /\ pSent \in SUBSET (Acceptors \X Epochs)
    /\ pVotes \in [Acceptors \X Epochs -> [Indexes -> Vote]]
    /\ pDrop \in [Acceptors \X Epochs -> SUBSET Indexes]
    /\ proposal \in [Epochs \X Indexes -> Values \cup {"none"}]
    /\ accs \in SUBSET (Acceptors \X Epochs \X Indexes)
    /\ commits \in SUBSET (Epochs \X Indexes)

Init ==
    /\ promised = [a \in Acceptors |-> 0]
    /\ accepted = [a \in Acceptors |-> [s \in Indexes |-> NoVote]]
    /\ owner = [b \in Epochs |-> "none"]
    /\ dropped = [a \in Acceptors |-> {}]
    /\ pSent = {}
    /\ pVotes = [p \in Acceptors \X Epochs |-> [s \in Indexes |-> NoVote]]
    /\ pDrop = [p \in Acceptors \X Epochs |-> {}]
    /\ proposal = [p \in Epochs \X Indexes |-> "none"]
    /\ accs = {}
    /\ commits = {}

\* A phase-two quorum has accepted the proposal of epoch b at index s.
AcceptedByQuorum(b, s) ==
    \E Q \in Quorum2 : \A a \in Q : <<a, b, s>> \in accs

DecidedAt(b, s, v) == proposal[<<b, s>>] = v /\ AcceptedByQuorum(b, s)

Decided(s, v) == \E b \in Epochs : DecidedAt(b, s, v)

-----------------------------------------------------------------------------
(* The actions, in the same order and with the same names as in            *)
(* FlexiblePaxos.tla.                                                      *)

Prepare(a, b) ==
    /\ owner[b] = "none"
    /\ owner' = [owner EXCEPT ![b] = a]
    /\ UNCHANGED <<promised, accepted, dropped, pSent, pVotes, pDrop, proposal, accs, commits>>

Promise(a, b) ==
    /\ owner[b] # "none"
    /\ b > promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ pSent' = pSent \cup {<<a, b>>}
    /\ pVotes' = [pVotes EXCEPT ![<<a, b>>] =
                    [s \in Indexes |-> IF s \in dropped[a] THEN NoVote ELSE accepted[a][s]]]
    /\ pDrop' = [pDrop EXCEPT ![<<a, b>>] = dropped[a]]
    /\ UNCHANGED <<accepted, owner, dropped, proposal, accs, commits>>

Propose(b, s, v) ==
    /\ proposal[<<b, s>>] = "none"
    /\ owner[b] # "none"
    /\ LearnedGuard => accepted[owner[b]][s].epoch # Learned
    /\ \E Q \in Quorum1 :
          /\ \A a \in Q : <<a, b>> \in pSent /\ s \notin pDrop[<<a, b>>]
          /\ \/ \A a \in Q : pVotes[<<a, b>>][s].epoch = -1
             \/ \E a \in Q :
                   /\ pVotes[<<a, b>>][s].val = v
                   /\ \A a2 \in Q : pVotes[<<a2, b>>][s].epoch <= pVotes[<<a, b>>][s].epoch
    /\ proposal' = [proposal EXCEPT ![<<b, s>>] = v]
    /\ UNCHANGED <<promised, accepted, owner, dropped, pSent, pVotes, pDrop, accs, commits>>

Accept(a, b, s) ==
    /\ proposal[<<b, s>>] # "none"
    /\ b >= promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ IF accepted[a][s].epoch = Learned
          THEN UNCHANGED accepted
          ELSE accepted' = [accepted EXCEPT ![a][s] = [epoch |-> b, val |-> proposal[<<b, s>>]]]
    /\ accs' = accs \cup {<<a, b, s>>}
    /\ UNCHANGED <<owner, dropped, pSent, pVotes, pDrop, proposal, commits>>

Leads(a, b) == owner[b] = a /\ promised[a] = b

LeaderLearn(b, s) ==
    /\ owner[b] # "none"
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].epoch # Learned
    /\ proposal[<<b, s>>] # "none"
    /\ AcceptedByQuorum(b, s)
    /\ accepted' = [accepted EXCEPT ![owner[b]][s] = [epoch |-> Learned, val |-> proposal[<<b, s>>]]]
    /\ UNCHANGED <<promised, owner, dropped, pSent, pVotes, pDrop, proposal, accs, commits>>

Conflict(b) ==
    \E s \in Indexes :
        /\ proposal[<<b, s>>] # "none"
        /\ accepted[owner[b]][s].epoch = Learned
        /\ accepted[owner[b]][s].val # proposal[<<b, s>>]

SendCommit(b, s) ==
    /\ owner[b] # "none"
    /\ Leads(owner[b], b)
    /\ accepted[owner[b]][s].epoch = Learned
    /\ ~ Conflict(b)
    /\ commits' = commits \cup {<<b, s>>}
    /\ UNCHANGED <<promised, accepted, owner, dropped, pSent, pVotes, pDrop, proposal, accs>>

FollowerCommit(a, b, s) ==
    /\ <<b, s>> \in commits
    /\ b >= promised[a]
    /\ accepted[a][s].epoch = b
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ accepted' = [accepted EXCEPT ![a][s] = [epoch |-> Learned, val |-> accepted[a][s].val]]
    /\ UNCHANGED <<owner, dropped, pSent, pVotes, pDrop, proposal, accs, commits>>

CatchUp(a, from, s) ==
    /\ accepted[from][s].epoch = Learned
    /\ accepted[a][s].epoch # Learned
    /\ accepted' = [accepted EXCEPT ![a][s] = accepted[from][s]]
    /\ UNCHANGED <<promised, owner, dropped, pSent, pVotes, pDrop, proposal, accs, commits>>

Snapshot(a, s) ==
    /\ accepted[a][s].epoch = Learned
    /\ s \notin dropped[a]
    /\ dropped' = [dropped EXCEPT ![a] = dropped[a] \cup {s}]
    /\ UNCHANGED <<promised, accepted, owner, pSent, pVotes, pDrop, proposal, accs, commits>>

Next ==
    \/ \E a \in Acceptors, b \in Epochs : Prepare(a, b)
    \/ \E a \in Acceptors, b \in Epochs : Promise(a, b)
    \/ \E b \in Epochs, s \in Indexes, v \in Values : Propose(b, s, v)
    \/ \E a \in Acceptors, b \in Epochs, s \in Indexes : Accept(a, b, s)
    \/ \E b \in Epochs, s \in Indexes : LeaderLearn(b, s)
    \/ \E b \in Epochs, s \in Indexes : SendCommit(b, s)
    \/ \E a \in Acceptors, b \in Epochs, s \in Indexes : FollowerCommit(a, b, s)
    \/ \E a \in Acceptors, from \in Acceptors, s \in Indexes : CatchUp(a, from, s)
    \/ \E a \in Acceptors, s \in Indexes : Snapshot(a, s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The safety properties, as in FlexiblePaxos.tla.                         *)

Agreement ==
    \A s \in Indexes, v1 \in Values, v2 \in Values :
        Decided(s, v1) /\ Decided(s, v2) => v1 = v2

LearnedSound ==
    \A a \in Acceptors, s \in Indexes :
        accepted[a][s].epoch = Learned => Decided(s, accepted[a][s].val)

LearnedAgree ==
    \A a1 \in Acceptors, a2 \in Acceptors, s \in Indexes :
        (accepted[a1][s].epoch = Learned /\ accepted[a2][s].epoch = Learned)
            => accepted[a1][s].val = accepted[a2][s].val

Safety == Agreement /\ LearnedSound /\ LearnedAgree

\* Equation 4.4 of the thesis.  This property is assumed of the constants.  It
\* is not proved.
QuorumIntersection ==
    \A Q1 \in Quorum1, Q2 \in Quorum2 : Q1 \cap Q2 # {}

-----------------------------------------------------------------------------
(* The inductive invariant.                                                *)

\* An acceptor that sent a promise for an epoch has promised at least that
\* epoch.  Some acceptor started that epoch.
PromisesSent ==
    \A a \in Acceptors, b \in Epochs :
        <<a, b>> \in pSent => owner[b] # "none" /\ promised[a] >= b

\* An accept refers to a proposal that exists.  The acceptor that sent the
\* accept has promised at least the epoch of the accept.  The entry of that
\* acceptor at the index is from that epoch or a later epoch, or is decided.
AcceptsSent ==
    \A a \in Acceptors, b \in Epochs, s \in Indexes :
        <<a, b, s>> \in accs =>
            /\ proposal[<<b, s>>] # "none"
            /\ promised[a] >= b
            /\ accepted[a][s].epoch >= b

\* An undecided entry equals the proposal of its epoch.  The acceptor that
\* holds the entry sent an accept for it.
EntriesAccepted ==
    \A a \in Acceptors, s \in Indexes :
        accepted[a][s].epoch \in Epochs =>
            /\ <<a, accepted[a][s].epoch, s>> \in accs
            /\ accepted[a][s].val = proposal[<<accepted[a][s].epoch, s>>]

\* An acceptor has dropped only indexes that it holds as decided.
DroppedLearned ==
    \A a \in Acceptors, s \in Indexes :
        s \in dropped[a] => accepted[a][s].epoch = Learned

\* For an index that a promise did not report as dropped, the report of the
\* promise is still accurate and complete for that acceptor, for all epochs
\* below the promised epoch:
\* - The acceptor accepted the entry that the promise reported.
\* - The acceptor accepted nothing after that entry in an epoch below the
\*   promised epoch.
\* - The acceptor will accept nothing in an epoch below the promised epoch.
PromisesHonest ==
    \A a \in Acceptors, b \in Epochs :
        <<a, b>> \in pSent =>
            /\ pDrop[<<a, b>>] \subseteq dropped[a]
            /\ \A s \in Indexes :
                  s \notin pDrop[<<a, b>>] =>
                      LET vt == pVotes[<<a, b>>][s] IN
                      /\ vt.epoch = Learned => Decided(s, vt.val)
                      /\ vt.epoch \in Epochs =>
                            /\ vt.epoch < b
                            /\ <<a, vt.epoch, s>> \in accs
                            /\ vt.val = proposal[<<vt.epoch, s>>]
                      /\ vt.epoch # Learned =>
                            \A c \in Epochs : (vt.epoch < c /\ c < b) => <<a, c, s>> \notin accs

\* This is the standard Paxos safety argument.  Every proposal is safe: for
\* every earlier epoch, a phase-one quorum exists in which each member
\* satisfies one of these:
\* - The member accepted the same value in that epoch.
\* - The member did not accept in that epoch and can no longer accept in that
\*   epoch.
\* Every phase-two quorum intersects that phase-one quorum.  Therefore no
\* other value was decided or will be decided in that epoch.
ProposalsSafe ==
    \A b \in Epochs, s \in Indexes :
        proposal[<<b, s>>] # "none" =>
            /\ owner[b] # "none"
            /\ \A c \in Epochs :
                  c < b =>
                      \E Q \in Quorum1 :
                          \A a \in Q :
                              \/ <<a, c, s>> \in accs /\ proposal[<<c, s>>] = proposal[<<b, s>>]
                              \/ <<a, c, s>> \notin accs /\ promised[a] > c

\* If a commit was sent for an index, the leader that sent the commit holds
\* that index as decided.  If that leader proposed at that index, the proposal
\* equals the decided value.  The leader never proposes at that index
\* afterwards, because `Propose` does not permit it.  This clause was not
\* inductive before `Propose` had that conjunct.
CommitsSound ==
    \A b \in Epochs, s \in Indexes :
        <<b, s>> \in commits =>
            /\ owner[b] # "none"
            /\ accepted[owner[b]][s].epoch = Learned
            /\ proposal[<<b, s>>] # "none" => accepted[owner[b]][s].val = proposal[<<b, s>>]

IndInv ==
    /\ TypeOK
    /\ PromisesSent
    /\ AcceptsSent
    /\ EntriesAccepted
    /\ DroppedLearned
    /\ PromisesHonest
    /\ ProposalsSafe
    /\ CommitsSound
    /\ LearnedSound

=============================================================================
