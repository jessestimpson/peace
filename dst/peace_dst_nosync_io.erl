%% This module is a planted bug. It replaces the file operations of
%% `peace_storage_wal' with operations that never sync. The simulated disk
%% of eta loses data that was not synced when the node of a server is
%% killed. The planted bug shows that `disk_recovers' in `peace_dst' can
%% fail with `disk => wal'.
-module(peace_dst_nosync_io).

-include("peace_eta.hrl").

-export([open/2, write/2, datasync/1, rename/2]).

open(File, Modes) -> file:open(File, Modes).

write(Fd, Data) -> file:write(Fd, Data).

datasync(_Fd) -> ok.

rename(From, To) -> file:rename(From, To).
