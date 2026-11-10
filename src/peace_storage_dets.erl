%% @doc Durable storage: one dets file per server, synced on every write.
%%
%% Args: `#{dir := file:name_all()}'. The file is named after the server.
%%
%% This is the simple backend, not the fast one. Every write is a `dets:sync',
%% so throughput is bounded by the disk's fsync rate, and dets caps a file at
%% 2 GB. A snapshot is one object, so the machine state has to fit too.
-module(peace_storage_dets).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

-include("peace_eta.hrl").

-define(PROMISED, '$promised').
-define(SNAPSHOT, '$snapshot').

open({Name, Node}, #{dir := Dir}) ->
    File = filename:join(Dir, lists:concat([Name, "@", Node, ".peace"])),
    ok = filelib:ensure_dir(File),
    %% An atom, one per server: a dets table may be named by any term, but
    %% the simulation's stand-in for dets wants an atom.
    Tab = binary_to_atom(<<"peace_storage_dets/", (atom_to_binary(Name))/binary, "@", (atom_to_binary(Node))/binary>>),
    {ok, Tab} = dets:open_file(Tab, [{file, to_list(File)}, {type, set}, {auto_save, infinity}]),
    Stored = dets:foldl(
        fun
            ({?PROMISED, Epoch}, Acc) ->
                Acc#{promised => Epoch};
            ({?SNAPSHOT, Snapshot}, Acc) ->
                Acc#{snapshot => Snapshot};
            ({Index, Entry}, Acc = #{entries := Entries}) when is_integer(Index) ->
                Acc#{entries := Entries#{Index => Entry}}
        end,
        #{entries => #{}},
        Tab
    ),
    {ok, Tab, Stored}.

write(Batch, Tab) ->
    Promised = [{?PROMISED, B} || {promised, B} <- maps:to_list(Batch)],
    Snapshot = [{?SNAPSHOT, S} || {snapshot, S} <- maps:to_list(Batch)],
    Entries = maps:get(entries, Batch, []),
    case Promised ++ Snapshot ++ Entries of
        [] ->
            {ok, Tab};
        Objects ->
            ok = dets:insert(Tab, Objects),
            %% After the snapshot is in, not before: a crash in between
            %% leaves entries the snapshot covers, which are ignored.
            _ = [
                dets:select_delete(Tab, [{{'$1', '_'}, [{is_integer, '$1'}, {'=<', '$1', Index}], [true]}])
             || {?SNAPSHOT, {Index, _}} <- Snapshot
            ],
            ok = dets:sync(Tab),
            {ok, Tab}
    end.

close(Tab) ->
    _ = dets:close(Tab),
    ok.

to_list(File) when is_binary(File) -> binary_to_list(File);
to_list(File) -> File.
