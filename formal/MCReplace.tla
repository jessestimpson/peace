----------------------------- MODULE MCReplace -----------------------------
(***************************************************************************)
(* Constants for model checking Replace.                                   *)
(*                                                                         *)
(* Four acceptors and two configurations with majority quorums:            *)
(*   - cA has a0, a1 and a2. a0 does not run. a0 stands for the            *)
(*     incarnation of a member that has lost its state.                    *)
(*   - cB has a1, a2 and a3. a3 runs and is not a member of cA. a3 stands  *)
(*     for the new incarnation at the address of a0.                       *)
(* The change from cA to cB replaces a0 with a3.                           *)
(***************************************************************************)
EXTENDS Replace, TLC

CONSTANTS a0, a1, a2, a3, cA, cB

MCMembers(c) == IF c = cA THEN {a0, a1, a2} ELSE {a1, a2, a3}

Pairs(S) == {Q \in SUBSET S : Cardinality(Q) = 2}

MCQ1(c) == Pairs(MCMembers(c))
MCQ2(c) == Pairs(MCMembers(c))

\* a1 and a2 are interchangeable.
Symm == Permutations({a1, a2})

=============================================================================
