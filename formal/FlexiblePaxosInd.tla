-------------------------- MODULE FlexiblePaxosInd --------------------------
(***************************************************************************)
(* FlexiblePaxos.tla again, in a form an inductive invariant can be        *)
(* checked for, and the invariant.                                         *)
(*                                                                         *)
(* TLC checks FlexiblePaxos by visiting every reachable state, which is    *)
(* why three epochs or two indexes take hours.  An inductive invariant is  *)
(* checked a step at a time: it holds initially, and any state satisfying  *)
(* it, reachable or not, steps only to states satisfying it.  Then it      *)
(* holds in every reachable state of every behaviour, however long, and    *)
(* the cost does not grow with the length of behaviours.  Apalache checks  *)
(* the three implications symbolically; see check_ind.sh.                  *)
(*                                                                         *)
(* The constants are still fixed for a check.  This is not a proof for     *)
(* every number of acceptors, epochs and indexes, which would take a proof *)
(* system (TLAPS).  It is the same guarantee TLC gives, for bounds TLC     *)
(* cannot reach.                                                           *)
(*                                                                         *)
(* What differs from FlexiblePaxos.tla                                     *)
(*   - No set of messages.  A set of records of different shapes has no    *)
(*     type Apalache accepts, and a symbolic "any set of messages" is far  *)
(*     larger than what the protocol can send.  Each kind of message is a  *)
(*     variable of its own, shaped by what can exist: one promise per      *)
(*     acceptor and epoch, one proposal per epoch and index.  A prepare is *)
(*     the fact that the epoch has an owner.                               *)
(*   - None is the string "none".                                          *)
(*   - The safeguards are on, but for `LearnedGuard`; the other mutations  *)
(*     are FlexiblePaxos.tla's.                                            *)
(*                                                                         *)
(* That this is the same protocol is checked, not assumed.                 *)
(* FPaxosIndRefines.tla rebuilds FlexiblePaxos's message set from these    *)
(* variables, and TLC checks that every behaviour of this spec is, under   *)
(* that mapping, a behaviour of FlexiblePaxos.                             *)
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
    \* TRUE: a leader does not propose in an index it holds decided.  FALSE
    \* is the model as it was before 2026-11-11, kept so that check_ind.sh
    \* can show the invariant is not inductive without it.
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
    \* Promises sent, as <<acceptor, epoch>>, and what each reported.
    \* @type: Set(<<Str, Int>>);
    pSent,
    \* @type: <<Str, Int>> -> (Int -> { epoch: Int, val: Str });
    pVotes,
    \* @type: <<Str, Int>> -> Set(Int);
    pDrop,
    \* proposal[<<b, s>>]: the value epoch b proposed at index s, or "none".
    \* @type: <<Int, Int>> -> Str;
    proposal,
    \* Accepts sent, as <<acceptor, epoch, index>>.
    \* @type: Set(<<Str, Int, Int>>);
    accs,
    \* Commits sent, as <<epoch, index>>.
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

\* A phase-two quorum has accepted epoch b's proposal at s.
AcceptedByQuorum(b, s) ==
    \E Q \in Quorum2 : \A a \in Q : <<a, b, s>> \in accs

DecidedAt(b, s, v) == proposal[<<b, s>>] = v /\ AcceptedByQuorum(b, s)

Decided(s, v) == \E b \in Epochs : DecidedAt(b, s, v)

-----------------------------------------------------------------------------
(* The actions, in FlexiblePaxos.tla's order and under its names.          *)

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
(* Safety, as in FlexiblePaxos.tla.                                        *)

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

\* Equation 4.4 of the thesis.  Assumed of the constants, not proved.
QuorumIntersection ==
    \A Q1 \in Quorum1, Q2 \in Quorum2 : Q1 \cap Q2 # {}

-----------------------------------------------------------------------------
(* The inductive invariant.                                                *)

\* A promise is from an acceptor that has promised at least that much, in an
\* epoch somebody started.
PromisesSent ==
    \A a \in Acceptors, b \in Epochs :
        <<a, b>> \in pSent => owner[b] # "none" /\ promised[a] >= b

\* An accept is for a proposal that exists, from an acceptor now promised at
\* least that far, whose entry is from that epoch or later unless decided.
AcceptsSent ==
    \A a \in Acceptors, b \in Epochs, s \in Indexes :
        <<a, b, s>> \in accs =>
            /\ proposal[<<b, s>>] # "none"
            /\ promised[a] >= b
            /\ accepted[a][s].epoch >= b

\* An undecided entry is the proposal of its epoch, and was acknowledged.
EntriesAccepted ==
    \A a \in Acceptors, s \in Indexes :
        accepted[a][s].epoch \in Epochs =>
            /\ <<a, accepted[a][s].epoch, s>> \in accs
            /\ accepted[a][s].val = proposal[<<accepted[a][s].epoch, s>>]

\* Only decided indexes are dropped.
DroppedLearned ==
    \A a \in Acceptors, s \in Indexes :
        s \in dropped[a] => accepted[a][s].epoch = Learned

\* What a promise reported of an index it had not dropped is still the whole
\* truth about that acceptor below the promised epoch: the entry it named
\* was accepted, nothing was accepted after it, and nothing will be.
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

\* The heart of Paxos.  A proposal is safe: for every earlier epoch there is
\* a phase-one quorum each of whose members either accepted this same value
\* in that epoch or never accepted in it and no longer can.  Every phase-two
\* quorum meets that quorum, so no other value was or will be decided there.
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

\* A commit index is the leader's word that it holds the index decided, and
\* that if it proposed there, its proposal is what was decided.  It never
\* proposes there afterwards: `Propose` refuses.  This is the clause that
\* could not be made true before `Propose` had that conjunct.
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
