-------------------------- MODULE FPaxosIndRefines --------------------------
(***************************************************************************)
(* This module is for TLC. It checks that FlexiblePaxosInd is the same     *)
(* protocol as FlexiblePaxos. `Msgs` rebuilds the message set of           *)
(* FlexiblePaxos.tla from the variables that FlexiblePaxosInd has in place *)
(* of the message set. `Refines` states that every behaviour of            *)
(* FlexiblePaxosInd, under that mapping, is a behaviour of FlexiblePaxos.  *)
(* The config also checks that IndInv holds in every reachable state. An   *)
(* inductive invariant must hold in every reachable state.                 *)
(*                                                                         *)
(* This module is not for Apalache. The types of Apalache do not allow a   *)
(* set of records with different fields.                                   *)
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
