%% @doc Durable storage in a write-ahead log.
%%
%% Args: `#{dir := file:name_all()}'. Each server has one directory below
%% `dir', named after the server.
%%
%% == Files ==
%%
%% The directory of a server contains the files of one generation `G':
%%
%% <ul>
%% <li>`G.ckpt' is the checkpoint. It contains the promised epoch, the
%%   snapshot, and the entries above the snapshot, as of the start of the
%%   generation. Generation 0 has no checkpoint. Generation 0 starts with
%%   no data.</li>
%% <li>`G.wal' is the log. It contains one record for each write since the
%%   start of the generation.</li>
%% </ul>
%%
%% A write without a snapshot appends one record to the log and syncs the
%% log. A write with `sync => false' appends the record and does not sync.
%% The sync of the next record covers it. A write with a snapshot starts
%% generation `G + 1':
%%
%% <ol>
%% <li>The backend writes the checkpoint to a temporary file and syncs the
%%   file.</li>
%% <li>The backend renames the temporary file to `G+1.ckpt' and syncs the
%%   directory.</li>
%% <li>The backend creates `G+1.wal' and syncs it.</li>
%% <li>The backend deletes the files of generation `G'.</li>
%% </ol>
%%
%% A crash at any point leaves a complete checkpoint with the highest
%% generation number. `open/2' uses that generation and deletes every other
%% file.
%%
%% == Records ==
%%
%% Each file starts with a 12-byte header: the bytes `peacewal' and a
%% 32-bit format version. A record is:
%%
%% <ul>
%% <li>a 32-bit marker,</li>
%% <li>the 64-bit length of the payload,</li>
%% <li>a 32-bit CRC of the length and the payload, and</li>
%% <li>the payload, in the external term format.</li>
%% </ul>
%%
%% == Damaged records ==
%%
%% `open/2' checks every record. A record is damaged if it is incomplete or
%% its CRC does not match.
%%
%% <ul>
%% <li>If no valid record follows the damaged record, the damaged record is
%%   a torn write: the server stopped while it wrote the record. The server
%%   sent nothing that depended on that write. `open/2' removes the record
%%   and every byte after it.</li>
%% <li>If a valid record follows the damaged record, data that was synced
%%   has been lost. `open/2' returns an error, and the server does not
%%   start.</li>
%% <li>A damaged checkpoint or a damaged header is also an error.</li>
%% </ul>
%%
%% A synced record that is damaged and is the last record of the log cannot
%% be told apart from a torn write. `open/2' removes it.
%%
%% == Limitations ==
%%
%% <ul>
%% <li>A checkpoint contains the whole snapshot in one record, so every
%%   snapshot rewrites the whole machine state.</li>
%% <li>The log is only shortened by a snapshot. With
%%   `snapshot_interval => infinity' the log grows without limit.</li>
%% <li>The backend holds in memory a map of the entries above the snapshot,
%%   to write them into the next checkpoint.</li>
%% </ul>
-module(peace_storage_wal).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

-include("peace_eta.hrl").

-define(HEADER, <<"peacewal", 1:32>>).
-define(MARKER, 16#70656163).

-record(wal, {
    dir :: file:filename_all(),
    %% `file', or a module that replaces `file' in a fault injection test.
    io :: module(),
    gen :: non_neg_integer(),
    fd :: file:io_device(),
    promised :: undefined | peace:epoch(),
    snapshot :: undefined | {peace:index(), peace_core:snapshot()},
    entries :: #{peace:index() => peace_core:entry()}
}).

%% ---------------------------------------------------------------------------
%% peace_storage
%% ---------------------------------------------------------------------------

open({Name, Node}, Args = #{dir := Base}) ->
    Dir = filename:join(Base, lists:concat([Name, "@", Node])),
    Io = maps:get(io, Args, file),
    ok = filelib:ensure_dir(filename:join(Dir, "file")),
    {ok, Names} = file:list_dir(Dir),
    _ = [file:delete(filename:join(Dir, N)) || N <- Names, filename:extension(N) =:= ".tmp"],
    Ckpts = [G || {G, ".ckpt"} <- [parse_name(N) || N <- Names]],
    Wals = [G || {G, ".wal"} <- [parse_name(N) || N <- Names]],
    Gen = lists:max([0 | Ckpts]),
    case Ckpts =:= [] andalso [G || G <- Wals, G > 0] =/= [] of
        true ->
            %% Only generation 0 has no checkpoint.
            {error, {missing_checkpoint, Dir}};
        false ->
            case read_checkpoint(Dir, Gen) of
                {ok, Promised0, Snapshot, Entries0} ->
                    _ = [
                        file:delete(path(Dir, G, Ext))
                     || {G, Ext} <- [{G, ".ckpt"} || G <- Ckpts] ++ [{G, ".wal"} || G <- Wals], G =/= Gen
                    ],
                    case replay(path(Dir, Gen, ".wal"), {Promised0, Entries0}) of
                        {ok, {Promised, Entries}} ->
                            {ok, Fd} = open_log(Io, Dir, Gen),
                            W = #wal{
                                dir = Dir,
                                io = Io,
                                gen = Gen,
                                fd = Fd,
                                promised = Promised,
                                snapshot = Snapshot,
                                entries = Entries
                            },
                            {ok, W, stored(W)};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

write(Batch = #{snapshot := _}, W) ->
    checkpoint(Batch, W);
write(Batch, W) when map_size(Batch) =:= 0 ->
    {ok, W};
write(Batch, W = #wal{io = Io, fd = Fd, promised = Promised0, entries = Entries0}) ->
    Record = record(maps:with([promised, entries], Batch)),
    case io_write(Io, Fd, Record) of
        ok ->
            %% A record that is written without a sync is covered by the
            %% sync of the next record, because the sync covers the file.
            Synced =
                case Batch of
                    #{sync := false} -> ok;
                    _ -> io_sync(Io, Fd)
                end,
            case Synced of
                ok ->
                    {Promised, Entries} = apply_batch(Batch, {Promised0, Entries0}),
                    {ok, W#wal{promised = Promised, entries = Entries}};
                {error, Reason} ->
                    {error, {sync, Reason}}
            end;
        {error, Reason} ->
            {error, {write, Reason}}
    end.

close(#wal{fd = Fd}) ->
    _ = file:close(Fd),
    ok.

%% ---------------------------------------------------------------------------
%% Checkpoints
%% ---------------------------------------------------------------------------

%% Starts the next generation. See "Files" in the module documentation.
checkpoint(Batch = #{snapshot := Snapshot = {Index, _}}, W = #wal{dir = Dir, io = Io, gen = Gen0, fd = Fd0}) ->
    {Promised, Entries0} = apply_batch(Batch, {W#wal.promised, W#wal.entries}),
    Entries = maps:filter(fun(I, _) -> I > Index end, Entries0),
    Gen = Gen0 + 1,
    Tmp = path(Dir, Gen, ".ckpt.tmp"),
    try
        {ok, TmpFd} = io_open(Io, Tmp, [write, raw, binary]),
        ok = io_write(Io, TmpFd, [?HEADER, record({Promised, Snapshot, Entries})]),
        ok = io_sync(Io, TmpFd),
        ok = file:close(TmpFd),
        ok = io_rename(Io, Tmp, path(Dir, Gen, ".ckpt")),
        ok = sync_dir(Io, Dir),
        {ok, Fd} = open_log(Io, Dir, Gen),
        _ = file:close(Fd0),
        _ = file:delete(path(Dir, Gen0, ".wal")),
        _ = file:delete(path(Dir, Gen0, ".ckpt")),
        {ok, W#wal{gen = Gen, fd = Fd, promised = Promised, snapshot = Snapshot, entries = Entries}}
    catch
        error:{badmatch, Error} -> {error, {checkpoint, Error}}
    end.

read_checkpoint(_Dir, 0) ->
    {ok, undefined, undefined, #{}};
read_checkpoint(Dir, Gen) ->
    File = path(Dir, Gen, ".ckpt"),
    case file:read_file(File) of
        {ok, <<Header:12/binary, Rest/binary>>} when Header =:= ?HEADER ->
            case next_record(Rest) of
                {ok, {Promised, Snapshot, Entries}, <<>>} -> {ok, Promised, Snapshot, Entries};
                _ -> {error, {damaged_checkpoint, File}}
            end;
        {ok, _} ->
            {error, {damaged_checkpoint, File}};
        {error, Reason} ->
            {error, {damaged_checkpoint, File, Reason}}
    end.

%% ---------------------------------------------------------------------------
%% The log
%% ---------------------------------------------------------------------------

%% Opens the log of a generation for appending. Creates the log if it does
%% not exist.
open_log(Io, Dir, Gen) ->
    File = path(Dir, Gen, ".wal"),
    case filelib:is_regular(File) of
        true ->
            io_open(Io, File, [append, raw, binary]);
        false ->
            case io_open(Io, File, [append, raw, binary]) of
                {ok, Fd} ->
                    case {io_write(Io, Fd, ?HEADER), io_sync(Io, Fd), sync_dir(Io, Dir)} of
                        {ok, ok, ok} -> {ok, Fd};
                        Error -> {error, {create_log, Error}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% Applies every record of the log to `Acc'. Removes a torn write from the
%% end of the log.
replay(File, Acc) ->
    case file:read_file(File) of
        {error, enoent} ->
            {ok, Acc};
        {ok, Bin} when byte_size(Bin) < byte_size(?HEADER) ->
            %% The server stopped while it created the log. `open_log/3'
            %% creates the log again.
            ok = file:delete(File),
            {ok, Acc};
        {ok, <<Header:12/binary, Rest/binary>>} when Header =:= ?HEADER ->
            replay(File, Rest, byte_size(Header), Acc);
        {ok, _} ->
            {error, {damaged_header, File}};
        {error, Reason} ->
            {error, {read, File, Reason}}
    end.

replay(_File, <<>>, _Offset, Acc) ->
    {ok, Acc};
replay(File, Bin, Offset, Acc) ->
    case next_record(Bin) of
        {ok, Batch, Rest} ->
            replay(File, Rest, Offset + byte_size(Bin) - byte_size(Rest), apply_batch(Batch, Acc));
        damaged ->
            case valid_record_follows(Bin) of
                true ->
                    {error, {damaged_record, File, Offset}};
                false ->
                    ok = truncate(File, Offset),
                    {ok, Acc}
            end
    end.

next_record(<<?MARKER:32, Len:64, Crc:32, Payload:Len/binary, Rest/binary>>) ->
    case erlang:crc32([<<Len:64>>, Payload]) of
        Crc -> {ok, binary_to_term(Payload), Rest};
        _ -> damaged
    end;
next_record(_Bin) ->
    damaged.

%% `Bin' starts with a damaged record. Returns whether a valid record
%% starts at any later position.
valid_record_follows(<<_, Rest/binary>>) ->
    lists:any(
        fun({Pos, _Len}) ->
            <<_:Pos/binary, Candidate/binary>> = Rest,
            next_record(Candidate) =/= damaged
        end,
        binary:matches(Rest, <<?MARKER:32>>)
    ).

truncate(File, Offset) ->
    {ok, Fd} = file:open(File, [read, write, raw, binary]),
    {ok, Offset} = file:position(Fd, Offset),
    ok = file:truncate(Fd),
    ok = file:sync(Fd),
    file:close(Fd).

record(Term) ->
    Payload = term_to_binary(Term),
    Len = byte_size(Payload),
    [<<?MARKER:32, Len:64, (erlang:crc32([<<Len:64>>, Payload])):32>>, Payload].

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

apply_batch(Batch, {Promised0, Entries0}) ->
    {
        maps:get(promised, Batch, Promised0),
        maps:merge(Entries0, maps:from_list(maps:get(entries, Batch, [])))
    }.

stored(#wal{promised = Promised, snapshot = Snapshot, entries = Entries}) ->
    maps:from_list(
        [{entries, Entries}] ++
            [{promised, Promised} || Promised =/= undefined] ++
            [{snapshot, Snapshot} || Snapshot =/= undefined]
    ).

path(Dir, Gen, Ext) ->
    filename:join(Dir, lists:flatten(io_lib:format("~16.16.0b~s", [Gen, Ext]))).

%% Returns `{Gen, Ext}' for the name of a checkpoint or a log, and `other'
%% for any other name.
parse_name(Name) ->
    Ext = filename:extension(Name),
    try list_to_integer(filename:rootname(Name), 16) of
        Gen when Ext =:= ".ckpt"; Ext =:= ".wal" -> {Gen, Ext};
        _ -> other
    catch
        error:badarg -> other
    end.

sync_dir(Io, Dir) ->
    case file:open(Dir, [read, raw, directory]) of
        {ok, Fd} ->
            Result = io_sync(Io, Fd),
            _ = file:close(Fd),
            Result;
        {error, Reason} ->
            {error, Reason}
    end.

%% The operations that a fault injection test replaces. The calls to `file'
%% are written out, so that the simulation can redirect them.
io_open(file, File, Modes) -> file:open(File, Modes);
io_open(Io, File, Modes) -> Io:open(File, Modes).

io_write(file, Fd, Data) -> file:write(Fd, Data);
io_write(Io, Fd, Data) -> Io:write(Fd, Data).

io_sync(file, Fd) -> file:datasync(Fd);
io_sync(Io, Fd) -> Io:datasync(Fd).

io_rename(file, From, To) -> file:rename(From, To);
io_rename(Io, From, To) -> Io:rename(From, To).
