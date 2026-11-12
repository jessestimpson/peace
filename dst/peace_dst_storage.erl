%% This module is the disk of the simulation. The disk is an ETS table that
%% the harness owns, so the data that a server wrote is still in the table
%% after the harness kills the server.
%%
%% Args: `#{tab := ets:table()}'. With `amnesia => true' the disk is empty
%% after a restart. This is the planted bug of the `amnesia' mode of
%% `peace_dst:init/2'.
%%
%% With `disk => {Mod, Args}', every write also goes to that backend. A
%% server that opens its storage receives the state that the backend
%% recovered, and not the state in the ETS table. If the two states differ,
%% the difference is recorded for `disk_recovers' to report.
%%
%% A batch with `sync => false' does not have to be durable until the next
%% batch without that key. See `peace_storage'. For each index of such a
%% batch, this module records the entry that the index held before the
%% batch. When a server opens its storage, the backend may have recovered
%% that earlier entry instead of the entry of the batch. This module then
%% changes the ETS table to match, and the two states do not differ.
%%
%% The shipped `peace_storage_dets' runs under the simulation in this way.
%% The dets calls of `peace_storage_dets' go to `eta_dets'. `eta_dets' keeps
%% the file but is not dets. The simulation therefore tests how the backend
%% uses dets, and does not test dets.
-module(peace_dst_storage).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).
-export([promised/2, entries/2, snapshot_index/2]).

open(Id, Args = #{tab := Tab}) ->
    case maps:get(amnesia, Args, false) of
        true -> true = ets:match_delete(Tab, {{Id, '_'}, '_'});
        false -> ok
    end,
    case Args of
        #{disk := {Mod, DiskArgs}, node := Node} ->
            %% The backend is opened on the node of the server, and the node
            %% is given by name. Table names are per node, and the first
            %% start of a server happens before the server is placed on a
            %% node.
            {ok, Disk, Recovered} = eta_net:with_node(Node, fun() -> peace_storage:open(Mod, Id, DiskArgs) end),
            ok = revert_unsynced(Tab, Id, maps:get(entries, Recovered, #{})),
            Stored = stored(Tab, Id),
            _ = Recovered =:= Stored orelse ets:insert(Tab, {{disk_differs, Id}, Recovered, Stored}),
            {ok, {Tab, Id, {Mod, Disk, Node}}, Recovered};
        _ ->
            {ok, {Tab, Id, none}, stored(Tab, Id)}
    end.

%% The state that the ETS table holds for a server.
stored(Tab, Id) ->
    Stored0 = #{entries => entries(Tab, Id)},
    Stored1 =
        case promised(Tab, Id) of
            undefined -> Stored0;
            Epoch -> Stored0#{promised => Epoch}
        end,
    case ets:lookup(Tab, {Id, snapshot}) of
        [{_, Snapshot}] -> Stored1#{snapshot => Snapshot};
        [] -> Stored1
    end.

write(Batch, {Tab, Id, {Mod, Disk0, Node}}) ->
    %% No code between the two writes yields to the scheduler, so a kill
    %% cannot happen between the two writes.
    {ok, Disk} = eta_net:with_node(Node, fun() -> peace_storage:write(Mod, Batch, Disk0) end),
    ok = note_unsynced(Batch, Tab, Id),
    {ok, _} = write(Batch, {Tab, Id, none}),
    {ok, {Tab, Id, {Mod, Disk, Node}}};
write(Batch, State = {Tab, Id, none}) ->
    Promised = [{{Id, promised}, B} || {promised, B} <- maps:to_list(Batch)],
    Entries = [{{Id, I}, Entry} || {I, Entry} <- maps:get(entries, Batch, [])],
    true = ets:insert(Tab, Promised ++ Entries),
    %% The record that the harness keeps of decided values is updated here,
    %% at the write. The record is not read from the disks between steps,
    %% because a server may decide an index and drop that index under a
    %% snapshot within one step.
    lists:foreach(
        fun
            ({I, {learned, Value}}) ->
                case ets:insert_new(Tab, {{decided, I}, Value}) of
                    true ->
                        ok;
                    false ->
                        case ets:lookup_element(Tab, {decided, I}, 2) of
                            Value -> ok;
                            Earlier -> ets:insert(Tab, {{conflict, I, Id}, Value, Earlier})
                        end
                end;
            (_) ->
                ok
        end,
        maps:get(entries, Batch, [])
    ),
    case Batch of
        #{snapshot := Snapshot = {Index, _}} ->
            true = ets:insert(Tab, {{Id, snapshot}, Snapshot}),
            _ = ets:select_delete(Tab, [
                {{{Id, '$1'}, '_'}, [{is_integer, '$1'}, {'=<', '$1', Index}], [true]}
            ]),
            peace_dst:bump(snapshots);
        _ ->
            ok
    end,
    {ok, State}.

%% Records, for each index of a batch that is not synced, the entry that the
%% index held before the batch. A synced batch makes every earlier batch
%% durable, so it removes these records.
note_unsynced(#{sync := false, entries := Entries}, Tab, Id) ->
    lists:foreach(
        fun({I, _Entry}) ->
            Before =
                case ets:lookup(Tab, {Id, I}) of
                    [{_, Entry0}] -> {entry, Entry0};
                    [] -> none
                end,
            ets:insert_new(Tab, {{unsynced, Id, I}, Before})
        end,
        Entries
    );
note_unsynced(_Batch, Tab, Id) ->
    true = ets:match_delete(Tab, {{unsynced, Id, '_'}, '_'}),
    ok.

%% For each index that was written without a sync: if the backend recovered
%% the entry that the index held before, the table is changed to hold that
%% entry.
revert_unsynced(Tab, Id, Recovered) ->
    lists:foreach(
        fun([I, Before]) ->
            case {Before, maps:find(I, Recovered)} of
                {{entry, Entry}, {ok, Entry}} ->
                    true = ets:insert(Tab, {{Id, I}, Entry}),
                    true = ets:delete(Tab, {unsynced, Id, I}),
                    peace_dst:bump(unsynced_lost);
                {none, error} ->
                    true = ets:delete(Tab, {Id, I}),
                    true = ets:delete(Tab, {unsynced, Id, I}),
                    peace_dst:bump(unsynced_lost);
                _ ->
                    ok
            end
        end,
        ets:match(Tab, {{unsynced, Id, '$1'}, '$2'})
    ).

close({_Tab, _Id, {Mod, Disk, Node}}) ->
    eta_net:with_node(Node, fun() -> peace_storage:close(Mod, Disk) end);
close(_State) ->
    ok.

promised(Tab, Id) ->
    case ets:lookup(Tab, {Id, promised}) of
        [{_, Epoch}] -> Epoch;
        [] -> undefined
    end.

entries(Tab, Id) ->
    maps:from_list([{I, Entry} || [I, Entry] <- ets:match(Tab, {{Id, '$1'}, '$2'}), is_integer(I)]).

snapshot_index(Tab, Id) ->
    case ets:lookup(Tab, {Id, snapshot}) of
        [{_, {Index, _}}] -> Index;
        [] -> 0
    end.
