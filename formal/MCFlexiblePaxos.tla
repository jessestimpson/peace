-------------------------- MODULE MCFlexiblePaxos --------------------------
(***************************************************************************)
(* Model-checking instances of FlexiblePaxos: the quorum systems           *)
(* `peace_quorum` implements, as definitions a .cfg can substitute for     *)
(* Quorum1 and Quorum2.                                                    *)
(***************************************************************************)
EXTENDS FlexiblePaxos, TLC

CONSTANTS
    Q1Size,     \* counting quorums: a phase-one quorum is any Q1Size acceptors
    Q2Size,     \* counting quorums: a phase-two quorum is any Q2Size acceptors
    GridRows    \* grid quorums: a set of disjoint rows covering Acceptors

\* peace_quorum: `majority` and `{counting, Q1, Q2}`.  Safe iff
\* Q1Size + Q2Size > Cardinality(Acceptors).  Over three acceptors, 3 and 1
\* is the thesis's Singleton Paxos and 1 and 3 its All aboard Paxos (section
\* 4.3.2); over four, 3 and 2 is the even nodes optimisation (section 4.3.3).
CountQ1 == {Q \in SUBSET Acceptors : Cardinality(Q) = Q1Size}
CountQ2 == {Q \in SUBSET Acceptors : Cardinality(Q) = Q2Size}

\* peace_quorum: `{grid, Rows}`.  Phase one needs one acceptor from every row
\* (a "column", not necessarily straight); phase two needs one whole row.
\* With two rows of two this is the thesis's example of section 4.1.3.  A
\* set that meets every row meets any one row, so they always intersect,
\* while two rows do not: replication survives the loss of all rows but one.
GridQ1 == {Q \in SUBSET Acceptors :
              /\ \A R \in GridRows : Cardinality(Q \cap R) = 1}
GridQ2 == GridRows

Symm == Permutations(Acceptors) \cup Permutations(Values)
ValueSymm == Permutations(Values)

=============================================================================
