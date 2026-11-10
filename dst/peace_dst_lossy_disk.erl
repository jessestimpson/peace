%% A planted bug: `peace_storage_dets' behind a layer that loses promises.
%% It shows that `disk_recovers' in `peace_dst' can fail.
-module(peace_dst_lossy_disk).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

open(Id, Args) -> peace_storage_dets:open(Id, Args).

write(Batch, State) -> peace_storage_dets:write(maps:remove(promised, Batch), State).

close(State) -> peace_storage_dets:close(State).
