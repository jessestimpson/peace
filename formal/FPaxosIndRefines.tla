-------------------------- MODULE FPaxosIndRefines --------------------------
(***************************************************************************)
(* For TLC: FlexiblePaxosInd is FlexiblePaxos.  `Msgs` rebuilds the        *)
(* message set of FlexiblePaxos.tla from the variables FlexiblePaxosInd    *)
(* keeps in its place, and `Refines` says that every behaviour of the one  *)
(* is, read that way, a behaviour of the other.  The config also checks    *)
(* that IndInv holds in every reachable state, which an inductive          *)
(* invariant must.                                                         *)
(*                                                                         *)
(* This module is not for Apalache: a set of records of different shapes   *)
(* is what its types do not allow.                                         *)
(***************************************************************************)
EXTENDS FlexiblePaxosInd


Msgs ==
         {[type |-> "prepare", epoch |-> b] : b \in {e \in Epochs : owner[e] # "none"}}
    \cup {[type |-> "promise", epoch |-> p[2], acc |-> p[1],
           votes |-> pVotes[p], dropped |-> pDrop[p]] : p \in pSent}
    \cup {[type |-> "propose", epoch |-> p[1], index |-> p[2], val |-> proposal[p]] :
            p \in {q \in Epochs \X Indexes : proposal[q] # "none"}}
    \cup {[type |-> "accept", epoch |-> t[2], index |-> t[3], acc |-> t[1]] : t \in accs}
    \cup {[type |-> "commit", epoch |-> c[1], index |-> c[2]] : c \in commits}

FP == INSTANCE FlexiblePaxos WITH
        msgs <- Msgs, None <- "none",
        FenceAccept <- TRUE, ConflictStepDown <- TRUE, Snapshots <- TRUE, SnapshotGuard <- TRUE

Refines == FP!Spec

=============================================================================
