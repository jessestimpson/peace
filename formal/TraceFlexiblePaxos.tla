------------------------- MODULE TraceFlexiblePaxos -------------------------
(***************************************************************************)
(* Trace validation: is one run of the code a behaviour of FlexiblePaxos?  *)
(*                                                                         *)
(* `TraceData` is written from a simulated run by dst/peace_dst_trace.erl, *)
(* which says how the run's steps become the actions below.  `Trace` is a  *)
(* sequence of them, each naming an action of FlexiblePaxos and its        *)
(* arguments.  The only behaviour of this spec takes them in order.  An    *)
(* action that is not enabled when its turn comes ends the behaviour, so   *)
(* the run is a behaviour of the model exactly when TLC gets to the end:   *)
(* a search of depth Len(Trace) + 1.  check_trace.sh compares the two.     *)
(*                                                                         *)
(* The last action of each step of the code also carries what the server   *)
(* then held, `chk`, and the model's `promised` and `accepted` must agree. *)
(* So the code may not merely do things the model allows: it must end up   *)
(* where the model does.                                                   *)
(*                                                                         *)
(* An "Invalid" action is a change the derivation found no action for.  It *)
(* is never enabled.                                                       *)
(***************************************************************************)
EXTENDS FlexiblePaxos, Sequences, TraceData

VARIABLE i      \* the next action of Trace to take

Step(e) ==
    CASE e.act = "Prepare"        -> Prepare(e.a, e.b)
      [] e.act = "Promise"        -> Promise(e.a, e.b)
      [] e.act = "Propose"        -> Propose(e.b, e.s, e.v)
      [] e.act = "Accept"         -> Accept(e.a, e.b, e.s)
      [] e.act = "LeaderLearn"    -> LeaderLearn(e.b, e.s)
      [] e.act = "SendCommit"     -> SendCommit(e.b, e.s)
      [] e.act = "FollowerCommit" -> FollowerCommit(e.a, e.b, e.s)
      [] e.act = "CatchUp"        -> CatchUp(e.a, e.from, e.s)
      [] e.act = "Snapshot"       -> Snapshot(e.a, e.s)
      [] OTHER                    -> FALSE

\* c = <<acceptor, promised, <<index, epoch, value>>, ...>>
Holds(c) ==
    /\ promised'[c[1]] = c[2]
    /\ \A k \in 1..Len(c[3]) :
          accepted'[c[1]][c[3][k][1]] = [epoch |-> c[3][k][2], val |-> c[3][k][3]]

TraceInit == Init /\ i = 1

TraceNext ==
    /\ i <= Len(Trace)
    /\ Step(Trace[i])
    /\ \A k \in 1..Len(Trace[i].chk) : Holds(Trace[i].chk[k])
    /\ i' = i + 1

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, i>>

=============================================================================
