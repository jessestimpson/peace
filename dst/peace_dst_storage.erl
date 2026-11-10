%% The simulation's disk: an ETS table the harness owns, so what a server
%% wrote is still there after the harness kills it.
%%
%% Args: `#{tab := ets:table()}', or with `amnesia => true' a disk that comes
%% back empty after a restart, which is the planted bug of
%% `peace_dst:init/2''s `amnesia' mode.
%%
%% With `disk => {Mod, Args}' every write goes to that backend as well, and
%% a server that opens is given what that backend recovered, not what is
%% here. If the two differ the difference is noted for `disk_recovers' to
%% report. That is how the shipped `peace_storage_dets' is run under the
%% simulation: its dets calls go to `eta_dets', which keeps the file but is
%% not dets, so this tests the backend's use of dets and not dets.
-module(peace_dst_storage).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).
-export([promised/2, entries/2, snapshot_index/2]).

open(Id, Args = #{tab := Tab}) ->
    case maps:get(amnesia, Args, false) of
        true -> true = ets:match_delete(Tab, {{Id, '_'}, '_'});
        false -> ok
    end,
    Stored0 = #{entries => entries(Tab, Id)},
    Stored1 =
        case promised(Tab, Id) of
            undefined -> Stored0;
            Epoch -> Stored0#{promised => Epoch}
        end,
    Stored =
        case ets:lookup(Tab, {Id, snapshot}) of
            [{_, Snapshot}] -> Stored1#{snapshot => Snapshot};
            [] -> Stored1
        end,
    case Args of
        #{disk := {Mod, DiskArgs}, node := Node} ->
            %% On the server's node by name: table names are per node, and
            %% the first start of a server is before it is placed on one.
            {ok, Disk, Recovered} = eta_net:with_node(Node, fun() -> peace_storage:open(Mod, Id, DiskArgs) end),
            _ = Recovered =:= Stored orelse ets:insert(Tab, {{disk_differs, Id}, Recovered, Stored}),
            {ok, {Tab, Id, {Mod, Disk, Node}}, Recovered};
        _ ->
            {ok, {Tab, Id, none}, Stored}
    end.

write(Batch, {Tab, Id, {Mod, Disk0, Node}}) ->
    %% Nothing between the two writes yields to the scheduler, so a kill
    %% cannot fall between them.
    {ok, Disk} = eta_net:with_node(Node, fun() -> peace_storage:write(Mod, Batch, Disk0) end),
    {ok, _} = write(Batch, {Tab, Id, none}),
    {ok, {Tab, Id, {Mod, Disk, Node}}};
write(Batch, State = {Tab, Id, none}) ->
    Promised = [{{Id, promised}, B} || {promised, B} <- maps:to_list(Batch)],
    Entries = [{{Id, I}, Entry} || {I, Entry} <- maps:get(entries, Batch, [])],
    true = ets:insert(Tab, Promised ++ Entries),
    %% The harness's record of what was decided is kept here, at the write,
    %% and not read off the disks between steps: a server may decide an index
    %% and drop it under a snapshot in the one step.
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
