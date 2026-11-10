------------------------------ MODULE Reconfig ------------------------------
(***************************************************************************)
(* Membership change for peace: Flexible Paxos in which the members and    *)
(* the quorum system are themselves decided in the log, and move from one  *)
(* configuration to the next through a joint one.                          *)
(*                                                                         *)
(* This is in the direction of revision B of Howard's thesis               *)
(* (UCAM-CL-TR-935, section 4.2), which lets the quorums differ between    *)
(* epochs and asks a phase-one quorum of epoch e to intersect the phase-two*)
(* quorums of every earlier epoch.  The thesis leaves open how a proposer  *)
(* knows what those earlier quorums were.  Here the log tells it.          *)
(*                                                                         *)
(* The scheme                                                              *)
(*   - A configuration is a set of members with its two quorum systems.    *)
(*   - A leader changes it with two log entries.  `joint(Old, New)` puts   *)
(*     both in force: a phase-two quorum is one of each.  Once that entry  *)
(*     is decided the leader proposes `final(New)`, after which New alone  *)
(*     is in force.  One change at a time.                                 *)
(*   - A leader's configuration is the latest such entry in its log,       *)
(*     decided or not, and failing any, the configuration as of what it    *)
(*     had applied when it campaigned.                                     *)
(*   - A candidate needs a phase-one quorum of every configuration it has  *)
(*     reason to think was in force for the indexes it asks about: the one *)
(*     it has applied, and every one named by a configuration entry in     *)
(*     the promises it receives (`UseClosure`).  A promise can therefore   *)
(*     raise the bar.                                                      *)
(*                                                                         *)
(* Why that is enough, informally.  A joint entry is decided under Old, so *)
(* any later candidate still on Old meets it in a promise and is then      *)
(* held to New as well.  Everything decided while the joint configuration  *)
(* is in force has a phase-two quorum of Old in it.  And `final(New)` is   *)
(* proposed only once the joint entry is decided, by which time no         *)
(* candidate can avoid needing a phase-one quorum of New.                  *)
(*                                                                         *)
(* One thing from FlexiblePaxos.tla is kept because this depends on it:    *)
(* a leader that learns an index was decided against its own proposal stops*)
(* (`Conflict`).  Without it a deposed leader whose joint entry lost could *)
(* take the index being decided for its entry being decided, and go on to  *)
(* `final`.  TLC finds that in nineteen steps.                             *)
(*                                                                         *)
(* What is left out is the rest of what FlexiblePaxos.tla covers: the      *)
(* commit index and snapshots.  Learning is one abstract action here.      *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Acceptors,
    Ordinary,           \* values that are not configuration entries
    Configs,        \* configuration names
    InitConfig,     \* the one every acceptor starts in
    Q1(_),          \* Q1(c): the phase-one quorums of configuration c
    Q2(_),          \* Q2(c): its phase-two quorums
    MaxEpoch,
    MaxIndex,
    None,
    UseJoint,       \* FALSE: a leader goes straight to `final`.  A mutation;
                    \* see ReconfigNoJoint.cfg.
    UseClosure      \* FALSE: a candidate asks only the configuration it has
                    \* applied.  A mutation; see ReconfigNoClosure.cfg.

VARIABLES
    promised,       \* promised[a]
    accepted,       \* accepted[a][s]: the proposal a last accepted for index s
    owner,          \* owner[b]: who started epoch b
    camp,           \* camp[b]: what its owner knew when it started
    msgs

vars == <<promised, accepted, owner, camp, msgs>>

Epochs == 1..MaxEpoch
Indexes   == 1..MaxIndex
Learned == MaxEpoch + 1

Joint(old, new) == [type |-> "joint", old |-> old, new |-> new]
Final(new)      == [type |-> "final", old |-> new, new |-> new]
ConfigEntries   == {Joint(o, n) : o \in Configs, n \in Configs} \cup {Final(n) : n \in Configs}
Values          == Ordinary \cup ConfigEntries

NoVote == [epoch |-> -1, val |-> None]

\* The configuration state: the set of configurations in force.  One, or
\* two while a change is under way.
InForce(e) == IF e.type = "joint" THEN {e.old, e.new} ELSE {e.new}

Init ==
    /\ promised = [a \in Acceptors |-> 0]
    /\ accepted = [a \in Acceptors |-> [s \in Indexes |-> NoVote]]
    /\ owner = [b \in Epochs |-> None]
    /\ camp = [b \in Epochs |-> [from |-> 1, base |-> {InitConfig}]]
    /\ msgs = {}

Send(m) == msgs' = msgs \cup {m}

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

IsLearned(a, s) == accepted[a][s].epoch = Learned

\* The first index a has not applied: decided indexes are applied in order.
FirstOpen(a) ==
    IF \A s \in Indexes : IsLearned(a, s) THEN MaxIndex + 1
    ELSE CHOOSE s \in Indexes : ~ IsLearned(a, s) /\ \A t \in 1..(s - 1) : IsLearned(a, t)

\* The configurations in force after a has applied indexes below `upto`.
Applied(a, upto) ==
    LET cfgIndexes == {s \in 1..(upto - 1) : accepted[a][s].val \in ConfigEntries}
    IN  IF cfgIndexes = {} THEN {InitConfig}
        ELSE InForce(accepted[a][Max(cfgIndexes)].val)

-----------------------------------------------------------------------------
(* peace: a candidate asks from its first unapplied index, and remembers   *)
(* the configuration it had applied.                                       *)
Prepare(a, b) ==
    /\ owner[b] = None
    /\ owner' = [owner EXCEPT ![b] = a]
    /\ camp' = [camp EXCEPT ![b] = [from |-> FirstOpen(a), base |-> Applied(a, FirstOpen(a))]]
    /\ Send([type |-> "prepare", epoch |-> b])
    /\ UNCHANGED <<promised, accepted>>

Promise(a, b) ==
    /\ [type |-> "prepare", epoch |-> b] \in msgs
    /\ b > promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ Send([type |-> "promise", epoch |-> b, acc |-> a, votes |-> accepted[a]])
    /\ UNCHANGED <<accepted, owner, camp>>

Proposals(b) == {m \in msgs : m.type = "propose" /\ m.epoch = b}

\* What the leader of b has in force: the latest configuration entry it has
\* proposed, or what it started with.
LeaderConfig(b) ==
    LET cfgs == {m \in Proposals(b) : m.val \in ConfigEntries}
    IN  IF cfgs = {} THEN camp[b].base
        ELSE LET last == CHOOSE m \in cfgs : \A n \in cfgs : n.index <= m.index
             IN  InForce(last.val)

\* peace_core steps down at this point: the leader of b holds an index decided
\* with a value other than the one it proposed there.
Conflict(b) ==
    \E m \in Proposals(b) :
        /\ accepted[owner[b]][m.index].epoch = Learned
        /\ accepted[owner[b]][m.index].val # m.val

\* Every configuration a set of promises gives the candidate reason to
\* respect, for the indexes it asked about.
Bar(b, reports) ==
    camp[b].base \cup
        (IF UseClosure
            THEN UNION {InForce(m.votes[s].val) :
                            <<m, s>> \in {<<m, s>> \in reports \X Indexes :
                                            /\ s >= camp[b].from
                                            /\ m.votes[s].val \in ConfigEntries}}
            ELSE {})

\* The promises of P are enough to lead epoch b.
Elected(b, P) ==
    LET reports == {m \in msgs : m.type = "promise" /\ m.epoch = b /\ m.acc \in P}
    IN  /\ \A a \in P : \E m \in reports : m.acc = a
        /\ \A c \in Bar(b, reports) : \E Q \in Q1(c) : Q \subseteq P

\* Whether the leader of b may introduce v, a value of its own, at index s.
\* Ordinary values always.  A configuration entry only when the last change is
\* over: `joint` from a settled configuration, `final` once the leader
\* knows the joint entry is decided.
MayIntroduce(b, s, v) ==
    LET a    == owner[b]
        cfgs == {m \in Proposals(b) : m.val \in ConfigEntries /\ m.index < s}
        settled == \A m \in cfgs : IsLearned(a, m.index)
        now  == LeaderConfig(b)
    IN  \/ v \in Ordinary
        \/ /\ UseJoint
           /\ v \in ConfigEntries
           /\ v.type = "joint"
           /\ settled
           /\ Cardinality(now) = 1
           /\ now = {v.old}
           /\ v.new # v.old
        \/ /\ UseJoint
           /\ v \in ConfigEntries
           /\ v.type = "final"
           /\ settled
           /\ Cardinality(now) = 2
           /\ \E old \in now : now = {old, v.new} /\ old # v.new
        \/ /\ ~ UseJoint
           /\ v \in ConfigEntries
           /\ v.type = "final"
           /\ settled
           /\ Cardinality(now) = 1
           /\ v.new \notin now

(* peace: the leader proposes index by index from where it asked.  An index*)
(* somebody reported is re-proposed with the value of the highest epoch.   *)
Propose(b, s, v) ==
    /\ owner[b] # None
    /\ ~ Conflict(b)
    /\ s >= camp[b].from
    /\ ~ \E m \in Proposals(b) : m.index = s
    /\ \A t \in camp[b].from..(s - 1) : \E m \in Proposals(b) : m.index = t
    /\ \E P \in SUBSET Acceptors :
          LET reports == {m \in msgs : m.type = "promise" /\ m.epoch = b /\ m.acc \in P}
              votes   == {m.votes[s] : m \in reports}
          IN  /\ Elected(b, P)
              /\ \/ /\ \A vt \in votes : vt.epoch = -1
                    /\ MayIntroduce(b, s, v)
                 \/ \E vt \in votes :
                       /\ vt.epoch # -1
                       /\ vt.epoch = Max({w.epoch : w \in votes})
                       /\ vt.val = v
    /\ Send([type |-> "propose", epoch |-> b, index |-> s, val |-> v])
    /\ UNCHANGED <<promised, accepted, owner, camp>>

Accept(a, b, s) ==
    /\ \E m \in Proposals(b) :
          /\ m.index = s
          /\ b >= promised[a]
          /\ promised' = [promised EXCEPT ![a] = b]
          /\ IF IsLearned(a, s)
                THEN UNCHANGED accepted
                ELSE accepted' = [accepted EXCEPT ![a][s] = [epoch |-> b, val |-> m.val]]
    /\ Send([type |-> "accept", epoch |-> b, index |-> s, acc |-> a])
    /\ UNCHANGED <<owner, camp>>

(* peace: the leader counts acknowledgements against what it has in force  *)
(* now: a phase-two quorum of each configuration.                          *)
LeaderLearn(b, s) ==
    LET a == owner[b]
        acks == {x \in Acceptors : [type |-> "accept", epoch |-> b, index |-> s, acc |-> x] \in msgs}
    IN  /\ a # None
        /\ promised[a] = b
        /\ ~ Conflict(b)
        /\ ~ IsLearned(a, s)
        /\ \E m \in Proposals(b) :
              /\ m.index = s
              /\ \A c \in LeaderConfig(b) : \E Q \in Q2(c) : Q \subseteq acks
              /\ accepted' = [accepted EXCEPT ![a][s] = [epoch |-> Learned, val |-> m.val]]
        /\ UNCHANGED <<promised, owner, camp, msgs>>

(* peace: every way a server learns an index from one that has decided it. *)
Learn(a, from, s) ==
    /\ IsLearned(from, s)
    /\ ~ IsLearned(a, s)
    /\ accepted' = [accepted EXCEPT ![a][s] = accepted[from][s]]
    /\ UNCHANGED <<promised, owner, camp, msgs>>

Next ==
    \/ \E a \in Acceptors, b \in Epochs : Prepare(a, b)
    \/ \E a \in Acceptors, b \in Epochs : Promise(a, b)
    \/ \E b \in Epochs, s \in Indexes, v \in Values : Propose(b, s, v)
    \/ \E a \in Acceptors, b \in Epochs, s \in Indexes : Accept(a, b, s)
    \/ \E b \in Epochs, s \in Indexes : LeaderLearn(b, s)
    \/ \E a, from \in Acceptors, s \in Indexes : Learn(a, from, s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* No two servers decide an index differently.
LearnedAgree ==
    \A a1, a2 \in Acceptors, s \in Indexes :
        (IsLearned(a1, s) /\ IsLearned(a2, s)) => accepted[a1][s].val = accepted[a2][s].val

\* Reachability: each is meant to FAIL.

\* No change ever completes.
NeverFinal == \A a \in Acceptors, s \in Indexes :
    ~ (IsLearned(a, s) /\ accepted[a][s].val \in ConfigEntries /\ accepted[a][s].val.type = "final")

\* No promise ever raises the bar.
NeverRaised == \A b \in Epochs :
    \A P \in SUBSET Acceptors :
        LET reports == {m \in msgs : m.type = "promise" /\ m.epoch = b /\ m.acc \in P}
        IN  Bar(b, reports) = camp[b].base

=============================================================================
