------------------------- MODULE MCFlexiblePaxosInd -------------------------
(***************************************************************************)
(* Instances of FlexiblePaxosInd for Apalache: `--cinit` names one of the  *)
(* operators below.  See check_ind.sh.                                     *)
(***************************************************************************)
EXTENDS FlexiblePaxosInd

\* Three acceptors, majorities.
Const3 ==
    /\ LearnedGuard = TRUE
    /\ Acceptors = {"a1", "a2", "a3"}
    /\ Values = {"v1", "v2"}
    /\ Quorum1 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}
    /\ Quorum2 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}

C3E2I1 == Const3 /\ MaxEpoch = 2 /\ MaxIndex = 1
C3E2I2 == Const3 /\ MaxEpoch = 2 /\ MaxIndex = 2
C3E3I1 == Const3 /\ MaxEpoch = 3 /\ MaxIndex = 1
C3E3I3 == Const3 /\ MaxEpoch = 3 /\ MaxIndex = 3
C3E4I4 == Const3 /\ MaxEpoch = 4 /\ MaxIndex = 4

\* Five acceptors: two to decide, four to elect.  Five are the fewest among
\* which the hole described in README.md could be reached.
Const5 ==
    /\ LearnedGuard = TRUE
    /\ Acceptors = {"a1", "a2", "a3", "a4", "a5"}
    /\ Values = {"v1", "v2"}
    /\ Quorum1 = {{"a1", "a2", "a3", "a4"}, {"a1", "a2", "a3", "a5"}, {"a1", "a2", "a4", "a5"},
                  {"a1", "a3", "a4", "a5"}, {"a2", "a3", "a4", "a5"}}
    /\ Quorum2 = {{"a1", "a2"}, {"a1", "a3"}, {"a1", "a4"}, {"a1", "a5"}, {"a2", "a3"},
                  {"a2", "a4"}, {"a2", "a5"}, {"a3", "a4"}, {"a3", "a5"}, {"a4", "a5"}}

C5E2I1 == Const5 /\ MaxEpoch = 2 /\ MaxIndex = 1
C5E3I3 == Const5 /\ MaxEpoch = 3 /\ MaxIndex = 3

\* Meant to fail.  Without the guard the step from IndInv does not keep
\* CommitsSound, even among three acceptors, where no reachable state shows
\* it and TLC found nothing.
NoGuard3 ==
    /\ LearnedGuard = FALSE
    /\ Acceptors = {"a1", "a2", "a3"}
    /\ Values = {"v1", "v2"}
    /\ Quorum1 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}
    /\ Quorum2 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}
    /\ MaxEpoch = 2
    /\ MaxIndex = 1

\* Meant to fail.  Two to elect and one to decide: the quorums need not
\* meet, and IndInv no longer implies Safety.
Unsafe3 ==
    /\ LearnedGuard = TRUE
    /\ Acceptors = {"a1", "a2", "a3"}
    /\ Values = {"v1", "v2"}
    /\ Quorum1 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}
    /\ Quorum2 = {{"a1"}, {"a2"}, {"a3"}}
    /\ MaxEpoch = 2
    /\ MaxIndex = 1

=============================================================================
