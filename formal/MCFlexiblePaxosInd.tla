------------------------- MODULE MCFlexiblePaxosInd -------------------------
(***************************************************************************)
(* Constants of FlexiblePaxosInd for Apalache. The `--cinit` option names  *)
(* one of the operators below. See check_ind.sh.                           *)
(***************************************************************************)
EXTENDS FlexiblePaxosInd

\* Three acceptors with majority quorums.
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

\* Five acceptors.  A phase-two quorum is any two acceptors.  A phase-one
\* quorum is any four acceptors.  The error described in README.md needs at
\* least five acceptors.  TLC reached it in FPaxosFiveAcceptors.cfg, which
\* uses quorums of three and three, not the quorums defined here.
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

\* This check must fail.  Without the guard, a step from a state that
\* satisfies IndInv does not preserve CommitsSound.  This is true even with
\* three acceptors.  With three acceptors no reachable state violates
\* CommitsSound, and TLC found no violation.
NoGuard3 ==
    /\ LearnedGuard = FALSE
    /\ Acceptors = {"a1", "a2", "a3"}
    /\ Values = {"v1", "v2"}
    /\ Quorum1 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}
    /\ Quorum2 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}
    /\ MaxEpoch = 2
    /\ MaxIndex = 1

\* This check must fail.  A phase-one quorum is any two acceptors.  A
\* phase-two quorum is any one acceptor.  A phase-one quorum does not always
\* intersect a phase-two quorum, and IndInv no longer implies Safety.
Unsafe3 ==
    /\ LearnedGuard = TRUE
    /\ Acceptors = {"a1", "a2", "a3"}
    /\ Values = {"v1", "v2"}
    /\ Quorum1 = {{"a1", "a2"}, {"a1", "a3"}, {"a2", "a3"}}
    /\ Quorum2 = {{"a1"}, {"a2"}, {"a3"}}
    /\ MaxEpoch = 2
    /\ MaxIndex = 1

=============================================================================
