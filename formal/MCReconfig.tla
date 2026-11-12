----------------------------- MODULE MCReconfig -----------------------------
(***************************************************************************)
(* Constants for model checking Reconfig.                                  *)
(*                                                                         *)
(* Three acceptors and two configurations that have no members in common:  *)
(*   - cA has a1 and a2 under `{counting, 1, 2}`. Either acceptor can      *)
(*     lead, and both acceptors must accept.                               *)
(*   - cB has a3 alone.                                                    *)
(* A change between configurations that have no members in common is the   *)
(* hard case. Only the protocol connects the values decided before the     *)
(* change to the values decided after the change.                          *)
(***************************************************************************)
EXTENDS Reconfig, TLC

CONSTANTS a1, a2, a3, cA, cB

MCQ1(c) == IF c = cA THEN {{a1}, {a2}} ELSE {{a3}}
MCQ2(c) == IF c = cA THEN {{a1, a2}} ELSE {{a3}}

\* a1 and a2 are interchangeable.  a3 is not interchangeable with a1 or a2.
Symm == Permutations({a1, a2})

=============================================================================
