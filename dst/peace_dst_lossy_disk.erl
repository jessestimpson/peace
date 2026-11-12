%% This module is a planted bug. The module wraps `peace_storage_dets' in a
%% layer that does not write promises. The planted bug shows that
%% `disk_recovers' in `peace_dst' can fail.
-module(peace_dst_lossy_disk).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

open(Id, Args) -> peace_storage_dets:open(Id, Args).

write(Batch, State) -> peace_storage_dets:write(maps:remove(promised, Batch), State).

close(State) -> peace_storage_dets:close(State).
