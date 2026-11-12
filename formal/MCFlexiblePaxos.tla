-------------------------- MODULE MCFlexiblePaxos --------------------------
(***************************************************************************)
(* Constants for model checking FlexiblePaxos. This module defines the     *)
(* quorum systems that `peace_quorum` implements. A .cfg file can          *)
(* substitute these definitions for Quorum1 and Quorum2.                   *)
(***************************************************************************)
EXTENDS FlexiblePaxos, TLC

CONSTANTS
    Q1Size,     \* counting quorums: a phase-one quorum is any Q1Size acceptors
    Q2Size,     \* counting quorums: a phase-two quorum is any Q2Size acceptors
    GridRows    \* grid quorums: a set of disjoint rows that cover Acceptors

\* peace_quorum: `majority` and `{counting, Q1, Q2}`.  These quorums are safe
\* if and only if Q1Size + Q2Size > Cardinality(Acceptors).
\* - Over three acceptors, Q1Size = 3 and Q2Size = 1 is the Singleton Paxos of
\*   the thesis (section 4.3.2).
\* - Over three acceptors, Q1Size = 1 and Q2Size = 3 is the All aboard Paxos
\*   of the thesis (section 4.3.2).
\* - Over four acceptors, Q1Size = 3 and Q2Size = 2 is the even nodes
\*   optimisation (section 4.3.3).
CountQ1 == {Q \in SUBSET Acceptors : Cardinality(Q) = Q1Size}
CountQ2 == {Q \in SUBSET Acceptors : Cardinality(Q) = Q2Size}

\* peace_quorum: `{grid, Rows}`.
\* - A phase-one quorum has one acceptor from every row.  Such a set is a
\*   "column", but the column does not need to be straight.
\* - A phase-two quorum is one whole row.
\* Two rows of two acceptors are the example of section 4.1.3 of the thesis.
\* A set that intersects every row intersects any single row, so a phase-one
\* quorum always intersects a phase-two quorum.  Two rows do not intersect.
\* Replication therefore continues after the loss of all rows except one.
GridQ1 == {Q \in SUBSET Acceptors :
              /\ \A R \in GridRows : Cardinality(Q \cap R) = 1}
GridQ2 == GridRows

Symm == Permutations(Acceptors) \cup Permutations(Values)
ValueSymm == Permutations(Values)

=============================================================================
