------------------------------ MODULE Reconfig ------------------------------
(***************************************************************************)
(* Membership change for peace. This module is Flexible Paxos in which the *)
(* members and the quorum system are decided in the log. A change from one *)
(* configuration to the next configuration goes through a joint            *)
(* configuration.                                                          *)
(*                                                                         *)
(* The design is related to revision B of Howard's thesis (UCAM-CL-TR-935, *)
(* section 4.2). Revision B allows the quorums to differ between epochs.   *)
(* Revision B requires a phase-one quorum of epoch e to intersect the      *)
(* phase-two quorums of every earlier epoch. The thesis does not specify   *)
(* how a proposer learns the quorums of earlier epochs. In this module the *)
(* proposer learns them from the log.                                      *)
(*                                                                         *)
(* The scheme                                                              *)
(*   - A configuration is a set of members with two quorum systems.        *)
(*   - A leader changes the configuration with two log entries:            *)
(*       1. `joint(Old, New)` puts both configurations in force. A         *)
(*          phase-two quorum then consists of a phase-two quorum of Old    *)
(*          and a phase-two quorum of New.                                 *)
(*       2. When the joint entry is decided, the leader proposes           *)
(*          `final(New)`. After `final(New)`, only New is in force.        *)
(*     Only one change is in progress at a time.                           *)
(*   - The configuration of a leader is the latest configuration entry     *)
(*     that the leader has proposed in its epoch, whether that entry is    *)
(*     decided or not. If the leader has proposed no configuration entry,  *)
(*     the configuration of the leader is the configuration that the       *)
(*     leader had applied when it started its campaign.                    *)
(*   - A candidate needs a phase-one quorum of every configuration that    *)
(*     the candidate has reason to believe was in force for the indexes it *)
(*     asks about. These are the configuration the candidate has applied,  *)
(*     and every configuration named by a configuration entry in the       *)
(*     promises the candidate receives (`UseClosure`). A promise can       *)
(*     therefore add a configuration from which the candidate needs a      *)
(*     phase-one quorum.                                                   *)
(*                                                                         *)
(* Informal safety argument                                                *)
(*   - A joint entry is decided under Old. Any later candidate that is     *)
(*     still on Old therefore receives the joint entry in a promise. That  *)
(*     candidate then also needs a phase-one quorum of New.                *)
(*   - Every value decided while the joint configuration is in force was   *)
(*     accepted by a phase-two quorum of Old.                              *)
(*   - `final(New)` is proposed only after the joint entry is decided.     *)
(*     From that time, every candidate needs a phase-one quorum of New.    *)
(*                                                                         *)
(* This module keeps one rule from FlexiblePaxos.tla, because membership   *)
(* change depends on the rule. A leader stops when it learns that an index *)
(* was decided with a value different from its own proposal (`Conflict`).  *)
(* Without the rule, this sequence is possible:                            *)
(*   1. A deposed leader proposes a joint entry, and a different value is  *)
(*      decided at that index.                                             *)
(*   2. The leader learns that the index is decided and treats its own     *)
(*      joint entry as decided.                                            *)
(*   3. The leader proposes `final`.                                       *)
(* TLC finds this sequence in nineteen steps.                              *)
(*                                                                         *)
(* What is not modelled                                                    *)
(*   - The commit index and snapshots. FlexiblePaxos.tla models them.      *)
(*   - The separate ways of learning. Learning is one abstract action in   *)
(*     this module.                                                        *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Acceptors,
    Ordinary,           \* values that are not configuration entries
    Configs,        \* configuration names
    InitConfig,     \* the configuration that every acceptor starts in
    Q1(_),          \* Q1(c): the phase-one quorums of configuration c
    Q2(_),          \* Q2(c): the phase-two quorums of configuration c
    MaxEpoch,
    MaxIndex,
    None,
    UseJoint,       \* FALSE: a leader proposes `final` without a joint
                    \* entry.  FALSE is a mutation; see ReconfigNoJoint.cfg.
    UseClosure,     \* FALSE: a candidate asks only the configuration it has
                    \* applied.  FALSE is a mutation; see
                    \* ReconfigNoClosure.cfg.
    CoLocated       \* TRUE: a proposer is also an acceptor, and takes the
                    \* acceptor step in the same action as the proposer step
                    \* (thesis section 3.7).  A peace server does this:
                    \* - A candidate promises its own epoch when it starts
                    \*   the epoch.
                    \* - A leader accepts its own proposal when it makes the
                    \*   proposal.
                    \* - A server that has promised a later epoch no longer
                    \*   proposes in an earlier epoch.
                    \* With FALSE, these three things can happen in any order
                    \* or not happen.  FALSE allows more than peace can do
                    \* and has a larger state space; see
                    \* ReconfigThreeIndexes.cfg.

VARIABLES
    promised,       \* promised[a]
    accepted,       \* accepted[a][s]: the proposal that a last accepted for
                    \* index s
    owner,          \* owner[b]: the acceptor that started epoch b
    camp,           \* camp[b]: what the owner of epoch b knew when it started
                    \* epoch b
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

\* The configuration state is the set of configurations in force.  The set
\* has one configuration, or two configurations while a change is in progress.
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

\* The first index that a has not applied.  Decided indexes are applied in
\* order.
FirstOpen(a) ==
    IF \A s \in Indexes : IsLearned(a, s) THEN MaxIndex + 1
    ELSE CHOOSE s \in Indexes : ~ IsLearned(a, s) /\ \A t \in 1..(s - 1) : IsLearned(a, t)

\* The configurations in force after a has applied indexes below `upto`.
Applied(a, upto) ==
    LET cfgIndexes == {s \in 1..(upto - 1) : accepted[a][s].val \in ConfigEntries}
    IN  IF cfgIndexes = {} THEN {InitConfig}
        ELSE InForce(accepted[a][Max(cfgIndexes)].val)

-----------------------------------------------------------------------------
(* In peace, a candidate asks from its first unapplied index. The          *)
(* candidate remembers the configuration it had applied.                   *)
Prepare(a, b) ==
    /\ owner[b] = None
    /\ owner' = [owner EXCEPT ![b] = a]
    /\ camp' = [camp EXCEPT ![b] = [from |-> FirstOpen(a), base |-> Applied(a, FirstOpen(a))]]
    /\ IF CoLocated
          THEN /\ b > promised[a]
               /\ promised' = [promised EXCEPT ![a] = b]
               /\ msgs' = msgs \cup {[type |-> "prepare", epoch |-> b],
                                      [type |-> "promise", epoch |-> b, acc |-> a, votes |-> accepted[a]]}
          ELSE /\ Send([type |-> "prepare", epoch |-> b])
               /\ UNCHANGED promised
    /\ UNCHANGED accepted

Promise(a, b) ==
    /\ [type |-> "prepare", epoch |-> b] \in msgs
    /\ b > promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ Send([type |-> "promise", epoch |-> b, acc |-> a, votes |-> accepted[a]])
    /\ UNCHANGED <<accepted, owner, camp>>

Proposals(b) == {m \in msgs : m.type = "propose" /\ m.epoch = b}

\* The configurations that the leader of b has in force.  They are the
\* configurations of the latest configuration entry that the leader has
\* proposed.  If the leader has proposed no configuration entry, they are the
\* configurations that the leader had applied when it started epoch b.
LeaderConfig(b) ==
    LET cfgs == {m \in Proposals(b) : m.val \in ConfigEntries}
    IN  IF cfgs = {} THEN camp[b].base
        ELSE LET last == CHOOSE m \in cfgs : \A n \in cfgs : n.index <= m.index
             IN  InForce(last.val)

\* Conflict(b) holds when the leader of b holds an index as decided with a
\* value different from the value the leader proposed at that index.
\* peace_core steps down when this happens.
Conflict(b) ==
    \E m \in Proposals(b) :
        /\ accepted[owner[b]][m.index].epoch = Learned
        /\ accepted[owner[b]][m.index].val # m.val

\* Every configuration from which the candidate of epoch b needs a phase-one
\* quorum, given a set of promises.  The set contains the configurations the
\* candidate had applied, and the configurations named by the promises for
\* the indexes the candidate asked about.
Bar(b, reports) ==
    camp[b].base \cup
        (IF UseClosure
            THEN UNION {InForce(m.votes[s].val) :
                            <<m, s>> \in {<<m, s>> \in reports \X Indexes :
                                            /\ s >= camp[b].from
                                            /\ m.votes[s].val \in ConfigEntries}}
            ELSE {})

\* The promises from the acceptors in P are sufficient to lead epoch b.
Elected(b, P) ==
    LET reports == {m \in msgs : m.type = "promise" /\ m.epoch = b /\ m.acc \in P}
    IN  /\ \A a \in P : \E m \in reports : m.acc = a
        /\ \A c \in Bar(b, reports) : \E Q \in Q1(c) : Q \subseteq P

\* Whether the leader of b may propose v at index s, when v is a value that
\* the leader chose and not a value that a promise reported.
\* - The leader may always propose an ordinary value.
\* - The leader may propose a configuration entry only when the previous
\*   change is complete.  The leader may propose `joint` when one settled
\*   configuration is in force.  The leader may propose `final` when the
\*   leader knows that the joint entry is decided.
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

(* In peace, the leader proposes one index at a time, starting from the    *)
(* first index it asked about. At an index for which any promise reported  *)
(* a proposal, the leader proposes again the value of the highest epoch.   *)
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
    /\ IF CoLocated
          THEN /\ promised[owner[b]] = b
               /\ msgs' = msgs \cup {[type |-> "propose", epoch |-> b, index |-> s, val |-> v],
                                      [type |-> "accept", epoch |-> b, index |-> s, acc |-> owner[b]]}
               /\ IF IsLearned(owner[b], s)
                     THEN UNCHANGED accepted
                     ELSE accepted' = [accepted EXCEPT ![owner[b]][s] = [epoch |-> b, val |-> v]]
          ELSE /\ Send([type |-> "propose", epoch |-> b, index |-> s, val |-> v])
               /\ UNCHANGED accepted
    /\ UNCHANGED <<promised, owner, camp>>

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

(* In peace, the leader counts acknowledgements against the configurations *)
(* it has in force at that time. The leader needs a phase-two quorum of    *)
(* each configuration.                                                     *)
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

(* In peace, a server can learn an index in several ways from a server     *)
(* that holds the index as decided. This action represents all of them.    *)
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
\* No two servers hold different decided values at the same index.
LearnedAgree ==
    \A a1, a2 \in Acceptors, s \in Indexes :
        (IsLearned(a1, s) /\ IsLearned(a2, s)) => accepted[a1][s].val = accepted[a2][s].val

\* Reachability.  Each invariant below must FAIL.

\* No change ever completes.
NeverFinal == \A a \in Acceptors, s \in Indexes :
    ~ (IsLearned(a, s) /\ accepted[a][s].val \in ConfigEntries /\ accepted[a][s].val.type = "final")

\* No ordinary value is ever decided after a change has completed.  A
\* violation needs three indexes: one for the joint entry, one for the final
\* entry, and one for the ordinary value.
NeverAfterFinal == \A a \in Acceptors, s \in Indexes, t \in Indexes :
    ~ (/\ s < t
       /\ IsLearned(a, s) /\ accepted[a][s].val \in ConfigEntries /\ accepted[a][s].val.type = "final"
       /\ IsLearned(a, t) /\ accepted[a][t].val \in Ordinary)

\* No promise ever adds a configuration from which a candidate needs a
\* phase-one quorum.
NeverRaised == \A b \in Epochs :
    \A P \in SUBSET Acceptors :
        LET reports == {m \in msgs : m.type = "promise" /\ m.epoch = b /\ m.acc \in P}
        IN  Bar(b, reports) = camp[b].base

=============================================================================
