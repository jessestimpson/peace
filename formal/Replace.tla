------------------------------ MODULE Replace ------------------------------
(***************************************************************************)
(* Replacement of a member that has lost its state. This module extends    *)
(* Reconfig.tla. See "Member identity" in ROADMAP.md and in                *)
(* `peace_server`.                                                         *)
(*                                                                         *)
(* The thesis (UCAM-CL-TR-935, section 1.6) assumes a fixed set of         *)
(* participants and assumes that the persistent state of a participant is  *)
(* unchanged after a restart. Section 3.12, "Fail-stop model", describes   *)
(* the alternative: a participant that fails does not restart, and         *)
(* reconfiguration restores the fault tolerance. peace uses the fail-stop  *)
(* model for a server that has lost its state. A member is identified by   *)
(* its address and its incarnation, and a server that has lost its state   *)
(* has a new incarnation. The earlier incarnation is an acceptor that      *)
(* never answers again. The new incarnation is an acceptor that has        *)
(* promised nothing, and it becomes a member through a membership change.  *)
(*                                                                         *)
(* What this module adds to Reconfig.tla                                   *)
(*   - `alive` is the set of acceptors that run. An acceptor that does not *)
(*     run takes no step. An acceptor in this module is one incarnation.   *)
(*   - `Lose(a)`: acceptor a loses its state. With `NewIdentity`, a stops  *)
(*     and never runs again. Without `NewIdentity`, a continues with the   *)
(*     same identity and with no promise and no accepted proposal. That is *)
(*     a mutation; see ReplaceSameIdentity.cfg.                            *)
(*   - A joiner asks to become a member (`Request`). A leader sends a      *)
(*     challenge (`Challenge`), and the joiner answers (`Answer`).         *)
(*   - A leader introduces a joint entry only if every acceptor that the   *)
(*     entry adds has answered a challenge of the epoch of the leader.     *)
(*     Without `UseChallenge`, the request is enough. That is a mutation;  *)
(*     see ReplaceNoChallenge.cfg.                                         *)
(*                                                                         *)
(* A message is never removed from `msgs`, so a request of an acceptor     *)
(* that no longer runs can be received at any later time.                  *)
(*                                                                         *)
(* What is not modelled                                                    *)
(*   - The start of the new incarnation at the address of an acceptor that *)
(*     lost its state. The joiner in the model checking constants stands   *)
(*     for such an incarnation.                                            *)
(*   - A membership change that an operator requests. peace makes such a   *)
(*     change without a challenge.                                         *)
(***************************************************************************)
EXTENDS Reconfig

CONSTANTS
    Members(_),     \* Members(c): the acceptors of configuration c
    Running,        \* the acceptors that run in the initial state
    Lossy,          \* the acceptors that can lose their state
    Joiners,        \* the acceptors that ask to become members
    UseChallenge,   \* FALSE is a mutation; see ReplaceNoChallenge.cfg
    NewIdentity     \* FALSE is a mutation; see ReplaceSameIdentity.cfg

VARIABLES
    alive,          \* the acceptors that run
    seen            \* seen[b]: the acceptors that ran at some time after
                    \* epoch b started.  The variable is used only by the
                    \* invariant ReplacementIsLive.

rvars == <<promised, accepted, owner, camp, msgs, alive, seen>>

RInit ==
    /\ Init
    /\ alive = Running
    /\ seen = [b \in Epochs |-> {}]

Min(S) == CHOOSE x \in S : \A y \in S : x <= y

Lose(a) ==
    /\ a \in alive
    /\ a \in Lossy
    /\ IF NewIdentity
          THEN /\ alive' = alive \ {a}
               /\ UNCHANGED <<promised, accepted>>
          ELSE /\ promised' = [promised EXCEPT ![a] = 0]
               /\ accepted' = [accepted EXCEPT ![a] = [s \in Indexes |-> NoVote]]
               /\ UNCHANGED alive
    /\ UNCHANGED <<owner, camp, msgs, seen>>

Request(a) ==
    /\ a \in alive
    /\ a \in Joiners
    /\ Send([type |-> "request", acc |-> a])
    /\ UNCHANGED <<promised, accepted, owner, camp, alive, seen>>

Challenge(b, a) ==
    /\ owner[b] \in alive
    /\ promised[owner[b]] = b
    /\ [type |-> "request", acc |-> a] \in msgs
    /\ Send([type |-> "challenge", epoch |-> b, acc |-> a])
    /\ UNCHANGED <<promised, accepted, owner, camp, alive, seen>>

Answer(a, b) ==
    /\ a \in alive
    /\ [type |-> "challenge", epoch |-> b, acc |-> a] \in msgs
    /\ Send([type |-> "ok", epoch |-> b, acc |-> a])
    /\ UNCHANGED <<promised, accepted, owner, camp, alive, seen>>

\* The acceptors that a configuration entry adds.
Added(v) == IF v \in ConfigEntries /\ v.type = "joint" THEN Members(v.new) \ Members(v.old) ELSE {}

\* Whether a promise of epoch b reported v at index s.  The leader then
\* proposes v again and did not choose v itself.
Reported(b, s, v) ==
    \E m \in msgs : m.type = "promise" /\ m.epoch = b /\ m.votes[s].val = v

\* The leader of b may introduce v only if every acceptor that v adds has
\* shown that it runs.
Verified(b, s, v) ==
    \/ Reported(b, s, v)
    \/ \A a \in Added(v) :
          IF UseChallenge
             THEN [type |-> "ok", epoch |-> b, acc |-> a] \in msgs
             ELSE [type |-> "request", acc |-> a] \in msgs

RNext ==
    \/ \E a \in alive, b \in Epochs :
          /\ Prepare(a, b)
          /\ seen' = [seen EXCEPT ![b] = alive]
          /\ UNCHANGED alive
    \/ \E a \in alive, b \in Epochs : Promise(a, b) /\ UNCHANGED <<alive, seen>>
    \/ \E b \in Epochs, s \in Indexes, v \in Values :
          /\ owner[b] \in alive
          /\ Verified(b, s, v)
          /\ Propose(b, s, v)
          /\ UNCHANGED <<alive, seen>>
    \/ \E a \in alive, b \in Epochs, s \in Indexes : Accept(a, b, s) /\ UNCHANGED <<alive, seen>>
    \/ \E b \in Epochs, s \in Indexes :
          /\ owner[b] \in alive
          /\ LeaderLearn(b, s)
          /\ UNCHANGED <<alive, seen>>
    \/ \E a \in alive, from \in alive, s \in Indexes : Learn(a, from, s) /\ UNCHANGED <<alive, seen>>
    \/ \E a \in Acceptors : Lose(a)
    \/ \E a \in Acceptors : Request(a)
    \/ \E b \in Epochs, a \in Acceptors : Challenge(b, a)
    \/ \E a \in Acceptors, b \in Epochs : Answer(a, b)

RSpec == RInit /\ [][RNext]_rvars

-----------------------------------------------------------------------------
\* An acceptor that a joint entry adds ran at some time after the epoch
\* that introduced the entry started.  The epoch that introduced the entry
\* is the lowest epoch that proposed it.  A request of an acceptor that
\* stopped earlier therefore adds no member.
ReplacementIsLive ==
    \A m \in msgs :
        (m.type = "propose" /\ Added(m.val) # {}) =>
            LET first == Min({n.epoch : n \in {n \in msgs : n.type = "propose" /\ n.index = m.index /\ n.val = m.val}})
            IN  Added(m.val) \subseteq (seen[first] \cup {})

=============================================================================
