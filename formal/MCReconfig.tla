----------------------------- MODULE MCReconfig -----------------------------
(***************************************************************************)
(* Model-checking instances of Reconfig.                                   *)
(*                                                                         *)
(* Three acceptors and two configurations chosen to share nobody:          *)
(*   cA - a1 and a2, `{counting, 1, 2}': either may lead, both must        *)
(*        accept;                                                          *)
(*   cB - a3 alone.                                                        *)
(* Moving between configurations with no member in common is the hard      *)
(* case: nothing but the protocol connects what was decided before to      *)
(* what is decided after.                                                  *)
(***************************************************************************)
EXTENDS Reconfig, TLC

CONSTANTS a1, a2, a3, cA, cB

MCQ1(c) == IF c = cA THEN {{a1}, {a2}} ELSE {{a3}}
MCQ2(c) == IF c = cA THEN {{a1, a2}} ELSE {{a3}}

\* a1 and a2 are interchangeable; a3 is not.
Symm == Permutations({a1, a2})

=============================================================================
