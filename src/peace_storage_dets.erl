%% @doc Durable storage. Each server has one dets file. The file is synced on
%% every write.
%%
%% Args: `#{dir := file:name_all()}'. The file is named after the server.
%%
%% This backend is simple and is not fast.
%%
%% <ul>
%% <li>Every write calls `dets:sync', so throughput is bounded by the fsync
%%   rate of the disk.</li>
%% <li>dets limits a file to 2 GB.</li>
%% <li>A snapshot is one object, so the machine state must also fit in the
%%   file.</li>
%% </ul>
-module(peace_storage_dets).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

-include("peace_eta.hrl").

-define(PROMISED, '$promised').
-define(SNAPSHOT, '$snapshot').

open({Name, Node}, #{dir := Dir}) ->
    File = filename:join(Dir, lists:concat([Name, "@", Node, ".peace"])),
    ok = filelib:ensure_dir(File),
    %% The table name is an atom, one per server. dets accepts any term as a
    %% table name, but the simulation's replacement for dets requires an atom.
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
            %% The entries are deleted after the snapshot is inserted, not
            %% before. A crash between the insert and the delete leaves
            %% entries that the snapshot covers. Those entries are ignored.
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
