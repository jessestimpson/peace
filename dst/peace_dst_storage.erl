%% The simulation's disk: an ETS table the harness owns, so what a server
%% wrote is still there after the harness kills it.
%%
%% Args: `#{tab := ets:table()}', or with `amnesia => true' a disk that comes
%% back empty after a restart, which is the planted bug of
%% `peace_dst:init/2''s `amnesia' mode.
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
            Ballot -> Stored0#{promised => Ballot}
        end,
    Stored =
        case ets:lookup(Tab, {Id, snapshot}) of
            [{_, Snapshot}] -> Stored1#{snapshot => Snapshot};
            [] -> Stored1
        end,
    {ok, {Tab, Id}, Stored}.

write(Batch, State = {Tab, Id}) ->
    Promised = [{{Id, promised}, B} || {promised, B} <- maps:to_list(Batch)],
    Entries = [{{Id, I}, Entry} || {I, Entry} <- maps:get(entries, Batch, [])],
    true = ets:insert(Tab, Promised ++ Entries),
    %% The harness's record of what was decided is kept here, at the write,
    %% and not read off the disks between steps: a server may decide a slot
    %% and drop it under a snapshot in the one step.
    lists:foreach(
        fun
            ({I, {decided, Command}}) ->
                case ets:insert_new(Tab, {{decided, I}, Command}) of
                    true ->
                        ok;
                    false ->
                        case ets:lookup_element(Tab, {decided, I}, 2) of
                            Command -> ok;
                            Earlier -> ets:insert(Tab, {{conflict, I, Id}, Command, Earlier})
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

close(_State) ->
    ok.

promised(Tab, Id) ->
    case ets:lookup(Tab, {Id, promised}) of
        [{_, Ballot}] -> Ballot;
        [] -> undefined
    end.

entries(Tab, Id) ->
    maps:from_list([{I, Entry} || [I, Entry] <- ets:match(Tab, {{Id, '$1'}, '$2'}), is_integer(I)]).

snapshot_index(Tab, Id) ->
    case ets:lookup(Tab, {Id, snapshot}) of
        [{_, {Index, _}}] -> Index;
        [] -> 0
    end.
