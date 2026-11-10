------------------------------ MODULE Reconfig ------------------------------
(***************************************************************************)
(* Membership change for peace: Flexible Paxos in which the members and    *)
(* the quorum system are themselves decided in the log, and move from one  *)
(* configuration to the next through a joint one.                          *)
(*                                                                         *)
(* This is in the direction of revision B of Howard's thesis               *)
(* (UCAM-CL-TR-935, section 4.2), which lets the quorums differ between    *)
(* epochs and asks a phase-1 quorum of epoch e to intersect the phase-2    *)
(* quorums of every earlier epoch.  The thesis leaves open how a proposer  *)
(* knows what those earlier quorums were.  Here the log tells it.          *)
(*                                                                         *)
(* The scheme                                                              *)
(*   - A configuration is a set of members with its two quorum systems.    *)
(*   - A leader changes it with two log entries.  `joint(Old, New)` puts   *)
(*     both in force: a phase-2 quorum is one of each.  Once that entry    *)
(*     is decided the leader proposes `final(New)`, after which New alone  *)
(*     is in force.  One change at a time.                                 *)
(*   - A leader's configuration is the latest such entry in its log,       *)
(*     decided or not, and failing any, the configuration as of what it    *)
(*     had applied when it campaigned.                                     *)
(*   - A candidate needs a phase-1 quorum of every configuration it has    *)
(*     reason to think was in force for the slots it asks about: the one   *)
(*     it has applied, and every one named by a configuration entry in     *)
(*     the promises it receives (`UseClosure`).  A promise can therefore   *)
(*     raise the bar.                                                      *)
(*                                                                         *)
(* Why that is enough, informally.  A joint entry is decided under Old, so *)
(* any later candidate still on Old meets it in a promise and is then      *)
(* held to New as well.  Everything decided while the joint configuration  *)
(* is in force has a phase-2 quorum of Old in it.  And `final(New)` is     *)
(* proposed only once the joint entry is decided, by which time no         *)
(* candidate can avoid needing a phase-1 quorum of New.                    *)
(*                                                                         *)
(* One thing from FlexiblePaxos.tla is kept because this depends on it:    *)
(* a leader that learns a slot was decided against its own proposal stops  *)
(* (`Conflict`).  Without it a deposed leader whose joint entry lost could *)
(* take the slot being decided for its entry being decided, and go on to   *)
(* `final`.  TLC finds that in nineteen steps.                             *)
(*                                                                         *)
(* What is left out is the rest of what FlexiblePaxos.tla covers: the      *)
(* commit index and snapshots.  Learning is one abstract action here.      *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Acceptors,
    Cmds,           \* ordinary commands
    Configs,        \* configuration names
    InitConfig,     \* the one every acceptor starts in
    Q1(_),          \* Q1(c): the phase-1 quorums of configuration c
    Q2(_),          \* Q2(c): its phase-2 quorums
    MaxBallot,
    MaxSlot,
    None,
    UseJoint,       \* FALSE: a leader goes straight to `final`.  A mutation;
                    \* see ReconfigNoJoint.cfg.
    UseClosure      \* FALSE: a candidate asks only the configuration it has
                    \* applied.  A mutation; see ReconfigNoClosure.cfg.

VARIABLES
    promised,       \* promised[a]
    accepted,       \* accepted[a][s]: a's vote for slot s
    owner,          \* owner[b]: who started ballot b
    camp,           \* camp[b]: what its owner knew when it started
    msgs

vars == <<promised, accepted, owner, camp, msgs>>

Ballots == 1..MaxBallot
Slots   == 1..MaxSlot
Decided == MaxBallot + 1

Joint(old, new) == [type |-> "joint", old |-> old, new |-> new]
Final(new)      == [type |-> "final", old |-> new, new |-> new]
ConfigEntries   == {Joint(o, n) : o \in Configs, n \in Configs} \cup {Final(n) : n \in Configs}
Values          == Cmds \cup ConfigEntries

NoVote == [bal |-> -1, val |-> None]

\* The configuration state: the set of configurations in force.  One, or
\* two while a change is under way.
InForce(e) == IF e.type = "joint" THEN {e.old, e.new} ELSE {e.new}

Init ==
    /\ promised = [a \in Acceptors |-> 0]
    /\ accepted = [a \in Acceptors |-> [s \in Slots |-> NoVote]]
    /\ owner = [b \in Ballots |-> None]
    /\ camp = [b \in Ballots |-> [from |-> 1, base |-> {InitConfig}]]
    /\ msgs = {}

Send(m) == msgs' = msgs \cup {m}

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

IsDecided(a, s) == accepted[a][s].bal = Decided

\* The first slot a has not applied: decided slots are applied in order.
FirstOpen(a) ==
    IF \A s \in Slots : IsDecided(a, s) THEN MaxSlot + 1
    ELSE CHOOSE s \in Slots : ~ IsDecided(a, s) /\ \A t \in 1..(s - 1) : IsDecided(a, t)

\* The configurations in force after a has applied slots below `upto`.
Applied(a, upto) ==
    LET cfgSlots == {s \in 1..(upto - 1) : accepted[a][s].val \in ConfigEntries}
    IN  IF cfgSlots = {} THEN {InitConfig}
        ELSE InForce(accepted[a][Max(cfgSlots)].val)

-----------------------------------------------------------------------------
(* peace: a candidate asks from its first unapplied slot, and remembers    *)
(* the configuration it had applied.                                       *)
Phase1a(a, b) ==
    /\ owner[b] = None
    /\ owner' = [owner EXCEPT ![b] = a]
    /\ camp' = [camp EXCEPT ![b] = [from |-> FirstOpen(a), base |-> Applied(a, FirstOpen(a))]]
    /\ Send([type |-> "1a", bal |-> b])
    /\ UNCHANGED <<promised, accepted>>

Phase1b(a, b) ==
    /\ [type |-> "1a", bal |-> b] \in msgs
    /\ b > promised[a]
    /\ promised' = [promised EXCEPT ![a] = b]
    /\ Send([type |-> "1b", bal |-> b, acc |-> a, votes |-> accepted[a]])
    /\ UNCHANGED <<accepted, owner, camp>>

Proposals(b) == {m \in msgs : m.type = "2a" /\ m.bal = b}

\* What the leader of b has in force: the latest configuration entry it has
\* proposed, or what it started with.
LeaderConfig(b) ==
    LET cfgs == {m \in Proposals(b) : m.val \in ConfigEntries}
    IN  IF cfgs = {} THEN camp[b].base
        ELSE LET last == CHOOSE m \in cfgs : \A n \in cfgs : n.slot <= m.slot
             IN  InForce(last.val)

\* peace_core steps down at this point: the leader of b holds a slot decided
\* with a value other than the one it proposed there.
Conflict(b) ==
    \E m \in Proposals(b) :
        /\ accepted[owner[b]][m.slot].bal = Decided
        /\ accepted[owner[b]][m.slot].val # m.val

\* Every configuration a set of promises gives the candidate reason to
\* respect, for the slots it asked about.
Bar(b, reports) ==
    camp[b].base \cup
        (IF UseClosure
            THEN UNION {InForce(m.votes[s].val) :
                            <<m, s>> \in {<<m, s>> \in reports \X Slots :
                                            /\ s >= camp[b].from
                                            /\ m.votes[s].val \in ConfigEntries}}
            ELSE {})

\* The promises of P are enough to lead ballot b.
Elected(b, P) ==
    LET reports == {m \in msgs : m.type = "1b" /\ m.bal = b /\ m.acc \in P}
    IN  /\ \A a \in P : \E m \in reports : m.acc = a
        /\ \A c \in Bar(b, reports) : \E Q \in Q1(c) : Q \subseteq P

\* Whether the leader of b may introduce v, a value of its own, at slot s.
\* Commands always.  A configuration entry only when the last change is
\* over: `joint` from a settled configuration, `final` once the leader
\* knows the joint entry is decided.
MayIntroduce(b, s, v) ==
    LET a    == owner[b]
        cfgs == {m \in Proposals(b) : m.val \in ConfigEntries /\ m.slot < s}
        settled == \A m \in cfgs : IsDecided(a, m.slot)
        now  == LeaderConfig(b)
    IN  \/ v \in Cmds
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

(* peace: the leader proposes slot by slot from where it asked.  A slot    *)
(* somebody reported is re-proposed with the value of the highest ballot.  *)
Phase2a(b, s, v) ==
    /\ owner[b] # None
    /\ ~ Conflict(b)
    /\ s >= camp[b].from
    /\ ~ \E m \in Proposals(b) : m.slot = s
    /\ \A t \in camp[b].from..(s - 1) : \E m \in Proposals(b) : m.slot = t
    /\ \E P \in SUBSET Acceptors :
          LET reports == {m \in msgs : m.type = "1b" /\ m.bal = b /\ m.acc \in P}
              votes   == {m.votes[s] : m \in reports}
          IN  /\ Elected(b, P)
              /\ \/ /\ \A vt \in votes : vt.bal = -1
                    /\ MayIntroduce(b, s, v)
                 \/ \E vt \in votes :
                       /\ vt.bal # -1
                       /\ vt.bal = Max({w.bal : w \in votes})
                       /\ vt.val = v
    /\ Send([type |-> "2a", bal |-> b, slot |-> s, val |-> v])
    /\ UNCHANGED <<promised, accepted, owner, camp>>

Phase2b(a, b, s) ==
    /\ \E m \in Proposals(b) :
          /\ m.slot = s
          /\ b >= promised[a]
          /\ promised' = [promised EXCEPT ![a] = b]
          /\ IF IsDecided(a, s)
                THEN UNCHANGED accepted
                ELSE accepted' = [accepted EXCEPT ![a][s] = [bal |-> b, val |-> m.val]]
    /\ Send([type |-> "2b", bal |-> b, slot |-> s, acc |-> a])
    /\ UNCHANGED <<owner, camp>>

(* peace: the leader counts acknowledgements against what it has in force  *)
(* now: a phase-2 quorum of each configuration.                            *)
LeaderDecide(b, s) ==
    LET a == owner[b]
        acks == {x \in Acceptors : [type |-> "2b", bal |-> b, slot |-> s, acc |-> x] \in msgs}
    IN  /\ a # None
        /\ promised[a] = b
        /\ ~ Conflict(b)
        /\ ~ IsDecided(a, s)
        /\ \E m \in Proposals(b) :
              /\ m.slot = s
              /\ \A c \in LeaderConfig(b) : \E Q \in Q2(c) : Q \subseteq acks
              /\ accepted' = [accepted EXCEPT ![a][s] = [bal |-> Decided, val |-> m.val]]
        /\ UNCHANGED <<promised, owner, camp, msgs>>

(* peace: every way a server learns a slot from one that has decided it.   *)
Learn(a, from, s) ==
    /\ IsDecided(from, s)
    /\ ~ IsDecided(a, s)
    /\ accepted' = [accepted EXCEPT ![a][s] = accepted[from][s]]
    /\ UNCHANGED <<promised, owner, camp, msgs>>

Next ==
    \/ \E a \in Acceptors, b \in Ballots : Phase1a(a, b)
    \/ \E a \in Acceptors, b \in Ballots : Phase1b(a, b)
    \/ \E b \in Ballots, s \in Slots, v \in Values : Phase2a(b, s, v)
    \/ \E a \in Acceptors, b \in Ballots, s \in Slots : Phase2b(a, b, s)
    \/ \E b \in Ballots, s \in Slots : LeaderDecide(b, s)
    \/ \E a, from \in Acceptors, s \in Slots : Learn(a, from, s)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* No two servers decide a slot differently.
DecidedAgree ==
    \A a1, a2 \in Acceptors, s \in Slots :
        (IsDecided(a1, s) /\ IsDecided(a2, s)) => accepted[a1][s].val = accepted[a2][s].val

\* Reachability: each is meant to FAIL.

\* No change ever completes.
NeverFinal == \A a \in Acceptors, s \in Slots :
    ~ (IsDecided(a, s) /\ accepted[a][s].val \in ConfigEntries /\ accepted[a][s].val.type = "final")

\* No promise ever raises the bar.
NeverRaised == \A b \in Ballots :
    \A P \in SUBSET Acceptors :
        LET reports == {m \in msgs : m.type = "1b" /\ m.bal = b /\ m.acc \in P}
        IN  Bar(b, reports) = camp[b].base

=============================================================================
