%% @doc Durable storage: one dets file per server, synced on every write.
%%
%% Args: `#{dir := file:name_all()}'. The file is named after the server.
%%
%% This is the simple backend, not the fast one. Every write is a `dets:sync',
%% so throughput is bounded by the disk's fsync rate, and dets caps a file at
%% 2 GB. peace has no log compaction yet, so the file grows with the log.
-module(peace_storage_dets).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

-define(PROMISED, '$promised').

open({Name, Node}, #{dir := Dir}) ->
    File = filename:join(Dir, lists:concat([Name, "@", Node, ".peace"])),
    ok = filelib:ensure_dir(File),
    Tab = {?MODULE, Name, Node},
    {ok, Tab} = dets:open_file(Tab, [{file, to_list(File)}, {type, set}, {auto_save, infinity}]),
    Stored = dets:foldl(
        fun
            ({?PROMISED, Ballot}, Acc) ->
                Acc#{promised => Ballot};
            ({Index, Entry}, Acc = #{entries := Entries}) when is_integer(Index) ->
                Acc#{entries := Entries#{Index => Entry}}
        end,
        #{entries => #{}},
        Tab
    ),
    {ok, Tab, Stored}.

write(Batch, Tab) ->
    Promised = [{?PROMISED, B} || {promised, B} <- maps:to_list(Batch)],
    Entries = maps:get(entries, Batch, []),
    case Promised ++ Entries of
        [] ->
            {ok, Tab};
        Objects ->
            ok = dets:insert(Tab, Objects),
            ok = dets:sync(Tab),
            {ok, Tab}
    end.

close(Tab) ->
    _ = dets:close(Tab),
    ok.

to_list(File) when is_binary(File) -> binary_to_list(File);
to_list(File) -> File.
