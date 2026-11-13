%% @doc Durable storage in a write-ahead log.
%%
%% Args: `#{dir := file:name_all()}'. Each server has one directory below
%% `dir', named after the server. The optional key `checkpoint_chunk_bytes'
%% is the size of a chunk of a checkpoint. The default is 1048576.
%%
%% == Files ==
%%
%% The directory of a server contains the files of one generation `G':
%%
%% <ul>
%% <li>`G.ckpt' is the checkpoint. It contains the snapshot, the promised
%%   epoch, and the entries above the snapshot, as of the start of the
%%   generation. Generation 0 has no checkpoint. Generation 0 starts with
%%   no data.</li>
%% <li>`G.wal' is the log. It contains one record for each write since the
%%   start of the generation.</li>
%% </ul>
%%
%% A write without a snapshot appends one record to the log and syncs the
%% log. A write with `sync => false' appends the record and does not sync.
%% The sync of the next record covers it. A snapshot starts generation
%% `G + 1':
%%
%% <ol>
%% <li>The backend encodes the snapshot and writes it to a temporary file,
%%   as one record for each chunk of `checkpoint_chunk_bytes' bytes. The
%%   backend syncs the file after each chunk.</li>
%% <li>The backend writes one last record with the promised epoch and the
%%   entries above the snapshot, and syncs the file.</li>
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
%% == Writes during a checkpoint ==
%%
%% `snapshot_begin/2' performs the first part of step 1.
%% `snapshot_continue/1' writes one chunk for each call, and performs steps
%% 2 to 5 in the last call. `peace_writer' calls `write/2' between these
%% calls. Such a write appends to `G.wal', as before the checkpoint. The
%% last record of the checkpoint holds the promised epoch and the entries as
%% of step 2, so the checkpoint includes these writes. A checkpoint of a
%% large snapshot therefore delays another write by the time to write and
%% sync one chunk. There are two exceptions: `snapshot_begin/2' encodes the
%% whole snapshot (see `peace_chunks'), and the last call writes every
%% entry above the snapshot.
%%
%% A crash before step 3 leaves generation `G', with every write that was
%% made during the checkpoint.
%%
%% `write/2' with a snapshot performs the whole checkpoint in one call.
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
%% <li>Every checkpoint contains the whole snapshot, so every snapshot
%%   rewrites the whole machine state.</li>
%% <li>The backend holds the encoded snapshot in memory while it writes the
%%   checkpoint (see `peace_chunks'). `open/2' reads the whole checkpoint
%%   into memory.</li>
%% <li>The last call of a checkpoint writes every entry above the snapshot
%%   in one record.</li>
%% <li>The log is only shortened by a snapshot. With
%%   `snapshot_interval => infinity' the log grows without limit.</li>
%% <li>The backend holds in memory a map of the entries above the snapshot,
%%   to write them into the next checkpoint.</li>
%% </ul>
-module(peace_storage_wal).

-behaviour(peace_storage).

-export([open/2, write/2, close/1, snapshot_begin/2, snapshot_continue/1]).

-include("peace_eta.hrl").

-define(HEADER, <<"peacewal", 1:32>>).
-define(MARKER, 16#70656163).
-define(CHUNK_BYTES, 1048576).

%% A checkpoint that is being written.
-record(ckpt, {
    gen :: pos_integer(),
    tmp :: file:filename_all(),
    fd :: file:io_device(),
    index :: peace:index(),
    %% The chunks of the encoded snapshot that are not yet written, and the
    %% size of the encoded snapshot in bytes. See `peace_chunks'.
    chunks :: [iodata()],
    size :: non_neg_integer()
}).

-record(wal, {
    dir :: file:filename_all(),
    %% `file', or a module that replaces `file' in a fault injection test.
    io :: module(),
    gen :: non_neg_integer(),
    fd :: file:io_device(),
    promised :: undefined | peace:epoch(),
    entries :: #{peace:index() => peace_core:entry()},
    chunk :: pos_integer(),
    ckpt :: undefined | #ckpt{}
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
                                entries = Entries,
                                chunk = maps:get(checkpoint_chunk_bytes, Args, ?CHUNK_BYTES)
                            },
                            {ok, W, stored(W, Snapshot)};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

write(#{snapshot := _}, #wal{ckpt = #ckpt{}}) ->
    {error, checkpoint_in_progress};
write(Batch = #{snapshot := _}, W) ->
    {Promised, Entries} = apply_batch(Batch, {W#wal.promised, W#wal.entries}),
    finish(snapshot_begin(Batch, W#wal{promised = Promised, entries = Entries}));
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

%% @doc Starts a checkpoint. See "Files" and "Writes during a checkpoint"
%% in the module documentation. The result `more' means that
%% `snapshot_continue/1' must be called.
snapshot_begin(#{snapshot := _}, #wal{ckpt = #ckpt{}}) ->
    {error, checkpoint_in_progress};
snapshot_begin(#{snapshot := {Index, Snapshot}}, W = #wal{dir = Dir, io = Io, gen = Gen0}) ->
    Gen = Gen0 + 1,
    Tmp = path(Dir, Gen, ".ckpt.tmp"),
    try
        {ok, Fd} = io_open(Io, Tmp, [write, raw, binary]),
        ok = io_write(Io, Fd, ?HEADER),
        {Chunks, Size} = peace_chunks:encode(Snapshot, W#wal.chunk),
        {more, W#wal{ckpt = #ckpt{gen = Gen, tmp = Tmp, fd = Fd, index = Index, chunks = Chunks, size = Size}}}
    catch
        error:{badmatch, Error} -> {error, {checkpoint, Error}}
    end.

%% @doc Writes the next chunk of the checkpoint. The call after the last
%% chunk completes the checkpoint and returns `done'.
snapshot_continue(W = #wal{io = Io, ckpt = Ckpt = #ckpt{fd = Fd, chunks = [Chunk | Chunks]}}) ->
    %% The chunk is synced here, so that the sync of the last call does not
    %% cover the whole snapshot.
    case {io_write(Io, Fd, record({chunk, iolist_to_binary(Chunk)})), io_sync(Io, Fd)} of
        {ok, ok} -> {more, W#wal{ckpt = Ckpt#ckpt{chunks = Chunks}}};
        Error -> {error, {checkpoint, Error}}
    end;
snapshot_continue(W = #wal{dir = Dir, io = Io, gen = Gen0, fd = Fd0, promised = Promised, ckpt = Ckpt}) ->
    #ckpt{gen = Gen, tmp = Tmp, fd = TmpFd, index = Index, chunks = [], size = Size} = Ckpt,
    Entries = maps:filter(fun(I, _) -> I > Index end, W#wal.entries),
    try
        ok = io_write(Io, TmpFd, record({checkpoint, Promised, Index, Size, Entries})),
        ok = io_sync(Io, TmpFd),
        ok = file:close(TmpFd),
        ok = io_rename(Io, Tmp, path(Dir, Gen, ".ckpt")),
        ok = sync_dir(Io, Dir),
        {ok, Fd} = open_log(Io, Dir, Gen),
        _ = file:close(Fd0),
        _ = file:delete(path(Dir, Gen0, ".wal")),
        _ = file:delete(path(Dir, Gen0, ".ckpt")),
        {done, W#wal{gen = Gen, fd = Fd, entries = Entries, ckpt = undefined}}
    catch
        error:{badmatch, Error} -> {error, {checkpoint, Error}}
    end.

%% Performs the rest of a checkpoint in one call.
finish({more, W}) -> finish(snapshot_continue(W));
finish({done, W}) -> {ok, W};
finish({error, Reason}) -> {error, Reason}.

read_checkpoint(_Dir, 0) ->
    {ok, undefined, undefined, #{}};
read_checkpoint(Dir, Gen) ->
    File = path(Dir, Gen, ".ckpt"),
    case file:read_file(File) of
        {ok, <<Header:12/binary, Rest/binary>>} when Header =:= ?HEADER ->
            case read_chunks(Rest, []) of
                {ok, Promised, Snapshot, Entries} -> {ok, Promised, Snapshot, Entries};
                damaged -> {error, {damaged_checkpoint, File}}
            end;
        {ok, _} ->
            {error, {damaged_checkpoint, File}};
        {error, Reason} ->
            {error, {damaged_checkpoint, File, Reason}}
    end.

%% Reads the records of a checkpoint. `Chunks' holds the chunks of the
%% snapshot that were read, in reverse order.
read_chunks(Bin, Chunks) ->
    case next_record(Bin) of
        {ok, {chunk, Part}, Rest} ->
            read_chunks(Rest, [Part | Chunks]);
        {ok, {checkpoint, Promised, Index, Size, Entries}, <<>>} ->
            Ordered = lists:reverse(Chunks),
            try iolist_size(Ordered) =:= Size andalso {ok, peace_chunks:decode(Ordered)} of
                false -> damaged;
                {ok, Snapshot} -> {ok, Promised, {Index, Snapshot}, Entries}
            catch
                error:badarg -> damaged
            end;
        {ok, {Promised, Snapshot, Entries}, <<>>} when Chunks =:= [] ->
            %% A checkpoint that an earlier version of this module wrote. It
            %% holds the snapshot in one record.
            {ok, Promised, Snapshot, Entries};
        _ ->
            damaged
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

stored(#wal{promised = Promised, entries = Entries}, Snapshot) ->
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
