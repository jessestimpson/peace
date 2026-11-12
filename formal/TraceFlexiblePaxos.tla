------------------------- MODULE TraceFlexiblePaxos -------------------------
(***************************************************************************)
(* Trace validation. This module checks whether one run of the code is a   *)
(* behaviour of FlexiblePaxos.                                             *)
(*                                                                         *)
(* dst/peace_dst_trace.erl writes `TraceData` from a simulated run.        *)
(* dst/peace_dst_trace.erl also describes how the steps of the run are     *)
(* converted into the actions below. `Trace` is a sequence of actions.     *)
(* Each element names an action of FlexiblePaxos and gives the arguments   *)
(* of the action. This spec has one behaviour, which takes the actions in  *)
(* order. If an action is not enabled when it is the next action in the    *)
(* sequence, the behaviour ends. The run is therefore a behaviour of the   *)
(* model exactly when TLC reaches the end of `Trace`. In that case the     *)
(* depth of the search is Len(Trace) + 1. check_trace.sh compares the      *)
(* depth that TLC reports with Len(Trace) + 1.                             *)
(*                                                                         *)
(* The last action of each step of the code also carries `chk`, which is   *)
(* the state that the server held after the step. The `promised` and       *)
(* `accepted` of the model must equal that state. It is therefore not      *)
(* sufficient that the model permits each action of the code. The code     *)
(* must also reach the same state as the model.                            *)
(*                                                                         *)
(* An "Invalid" action is a change for which the derivation found no       *)
(* action. An "Invalid" action is never enabled.                           *)
(***************************************************************************)
EXTENDS FlexiblePaxos, Sequences, TraceData

VARIABLE i      \* the position in Trace of the next action to take

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

\* c = <<acceptor, promised, votes>>, where votes is a sequence of
\* <<index, epoch, value>> triples.
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
