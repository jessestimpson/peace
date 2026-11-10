%% The simulation's disk: an ETS table the harness owns, so what a server
%% wrote is still there after the harness kills it.
%%
%% Args: `#{tab := ets:table()}', or with `amnesia => true' a disk that comes
%% back empty after a restart, which is the planted bug of
%% `peace_dst:init/2''s `amnesia' mode.
-module(peace_dst_storage).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).
-export([promised/2, entries/2]).

open(Id, Args = #{tab := Tab}) ->
    case maps:get(amnesia, Args, false) of
        true -> true = ets:match_delete(Tab, {{Id, '_'}, '_'});
        false -> ok
    end,
    Stored0 = #{entries => entries(Tab, Id)},
    Stored =
        case promised(Tab, Id) of
            undefined -> Stored0;
            Ballot -> Stored0#{promised => Ballot}
        end,
    {ok, {Tab, Id}, Stored}.

write(Batch, State = {Tab, Id}) ->
    Promised = [{{Id, promised}, B} || {promised, B} <- maps:to_list(Batch)],
    Entries = [{{Id, I}, Entry} || {I, Entry} <- maps:get(entries, Batch, [])],
    true = ets:insert(Tab, Promised ++ Entries),
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
