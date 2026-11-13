%% Fault injection tests for `peace_storage_wal'. Each test damages the
%% files, or makes a file operation fail, and checks what the next open
%% recovers.
%%
%% The contract is:
%%   - A write that returned `ok' is recovered.
%%   - A write that returned an error is recovered completely or not at
%%     all.
%%   - Damage that loses a write that returned `ok' makes the open fail,
%%     except for damage to the last record of the log.
-module(peace_storage_wal_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ID, {peace_storage_wal_tests, node()}).
-define(IO, peace_storage_faulty_io).

%% Three batches and the data that an open recovers after each.
b1() -> #{promised => {1, ?ID}, entries => [{1, entry(1, a)}, {2, entry(1, b)}]}.
b2() -> #{entries => [{2, {learned, value(1, b)}}, {3, entry(1, c)}]}.
b3() -> #{promised => {2, ?ID}}.

s1() -> #{promised => {1, ?ID}, entries => #{1 => entry(1, a), 2 => entry(1, b)}}.
s2() -> (s1())#{entries := #{1 => entry(1, a), 2 => {learned, value(1, b)}, 3 => entry(1, c)}}.
s3() -> (s2())#{promised := {2, ?ID}}.

%% A snapshot at index 2, and the data that an open recovers after it.
snap() -> #{snapshot => {2, {state, #{}, cfg}}, entries => [{4, entry(2, d)}]}.
s4() -> #{promised => {2, ?ID}, snapshot => {2, {state, #{}, cfg}}, entries => #{3 => entry(1, c), 4 => entry(2, d)}}.

entry(Round, X) -> {{Round, ?ID}, value(Round, X)}.
value(Round, X) -> {'$usr', {{Round, ?ID}, 0}, {put, X}}.

failed_sync_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, W1} = peace_storage_wal:write(b1(), W0),
        ok = ?IO:arm({sync, eio}),
        ?assertEqual({error, {sync, eio}}, peace_storage_wal:write(b2(), W1)),
        ok = ?IO:disarm(),
        %% The record was written and not synced. Either result is correct.
        {_, Recovered} = open(Dir),
        ?assert(lists:member(Recovered, [s1(), s2()]))
    end).

full_disk_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, W1} = peace_storage_wal:write(b1(), W0),
        ok = ?IO:arm({write, 0, enospc}),
        ?assertEqual({error, {write, enospc}}, peace_storage_wal:write(b2(), W1)),
        ok = ?IO:disarm(),
        {W2, Recovered} = open(Dir),
        ?assertEqual(s1(), Recovered),
        %% The store is usable when the disk has space again.
        {ok, _} = peace_storage_wal:write(b2(), W2),
        {_, Recovered2} = open(Dir),
        ?assertEqual(s2(), Recovered2)
    end).

short_write_test() ->
    with_dir(fun(Dir) ->
        lists:foreach(
            fun(N) ->
                Sub = filename:join(Dir, integer_to_list(N)),
                {W0, _} = open(Sub),
                {ok, W1} = peace_storage_wal:write(b1(), W0),
                ok = ?IO:arm({write, N, enospc}),
                ?assertEqual({error, {write, enospc}}, peace_storage_wal:write(b2(), W1)),
                ok = ?IO:disarm(),
                {W2, Recovered} = open(Sub),
                ?assertEqual(s1(), Recovered, {short, N}),
                %% The open removed the partial record. A later write is
                %% recovered.
                {ok, _} = peace_storage_wal:write(b3(), W2),
                {_, Recovered2} = open(Sub),
                ?assertEqual((s1())#{promised := {2, ?ID}}, Recovered2, {short, N})
            end,
            [1, 4, 12, 15, 16, 17, 40]
        )
    end).

%% The log is cut at every length between the end of the first record and
%% the end of the second record. This is every torn write of the second
%% record.
torn_write_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, W1} = peace_storage_wal:write(b1(), W0),
        Log = log(Dir),
        {ok, Before} = file:read_file(Log),
        {ok, _} = peace_storage_wal:write(b2(), W1),
        {ok, After} = file:read_file(Log),
        lists:foreach(
            fun(Size) ->
                ok = file:write_file(Log, binary:part(After, 0, Size)),
                {_, Recovered} = open(Dir),
                ?assertEqual(s1(), Recovered, {cut, Size}),
                ?assertEqual({ok, Before}, file:read_file(Log), {cut, Size})
            end,
            lists:seq(byte_size(Before), byte_size(After) - 1)
        ),
        %% A torn write that left zeros in place of the record.
        ok = file:write_file(Log, [Before, binary:copy(<<0>>, byte_size(After) - byte_size(Before))]),
        ?assertMatch({_, _}, open(Dir)),
        ?assertEqual({ok, Before}, file:read_file(Log))
    end).

%% Every byte of the first record is changed in turn. A valid record
%% follows the first record, so every change must make the open fail.
damaged_record_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, W1} = peace_storage_wal:write(b1(), W0),
        Log = log(Dir),
        {ok, One} = file:read_file(Log),
        {ok, _} = peace_storage_wal:write(b2(), W1),
        {ok, Two} = file:read_file(Log),
        lists:foreach(
            fun(Pos) ->
                ok = file:write_file(Log, flip(Two, Pos)),
                ?assertMatch({error, {damaged_record, _, 12}}, peace_storage_wal:open(?ID, #{dir => Dir}), {flip, Pos})
            end,
            lists:seq(12, byte_size(One) - 1)
        ),
        %% Damage to the last record cannot be told apart from a torn write.
        %% The open removes the record.
        ok = file:write_file(Log, flip(Two, byte_size(Two) - 1)),
        {_, Recovered} = open(Dir),
        ?assertEqual(s1(), Recovered)
    end).

damaged_header_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, _} = peace_storage_wal:write(b1(), W0),
        Log = log(Dir),
        {ok, Bin} = file:read_file(Log),
        ok = file:write_file(Log, flip(Bin, 3)),
        ?assertMatch({error, {damaged_header, _}}, peace_storage_wal:open(?ID, #{dir => Dir}))
    end).

damaged_checkpoint_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, W1} = write_all([b1(), b2(), b3(), snap()], W0),
        ok = peace_storage_wal:close(W1),
        {_, Recovered} = open(Dir),
        ?assertEqual(s4(), Recovered),
        [Ckpt] = filelib:wildcard(filename:join([Dir, "*", "*.ckpt"])),
        {ok, Bin} = file:read_file(Ckpt),
        lists:foreach(
            fun(Pos) ->
                ok = file:write_file(Ckpt, flip(Bin, Pos)),
                ?assertMatch({error, {damaged_checkpoint, _}}, peace_storage_wal:open(?ID, #{dir => Dir}), {flip, Pos})
            end,
            lists:seq(0, byte_size(Bin) - 1)
        ),
        ok = file:write_file(Ckpt, binary:part(Bin, 0, byte_size(Bin) - 1)),
        ?assertMatch({error, {damaged_checkpoint, _}}, peace_storage_wal:open(?ID, #{dir => Dir}))
    end).

%% A checkpoint that fails leaves the previous generation complete.
failed_checkpoint_test() ->
    with_dir(fun(Dir) ->
        lists:foreach(
            fun(Fault) ->
                Sub = filename:join(Dir, integer_to_list(erlang:phash2(Fault))),
                {W0, _} = open(Sub),
                {ok, W1} = write_all([b1(), b2(), b3()], W0),
                ok = ?IO:arm(Fault),
                ?assertMatch({error, {checkpoint, _}}, peace_storage_wal:write(snap(), W1), Fault),
                ok = ?IO:disarm(),
                {W2, Recovered} = open(Sub),
                ?assertEqual(s3(), Recovered, Fault),
                %% The open removed the temporary file.
                ?assertEqual([], filelib:wildcard(filename:join([Sub, "*", "*.tmp"]))),
                {ok, _} = peace_storage_wal:write(snap(), W2),
                {_, Recovered2} = open(Sub),
                ?assertEqual(s4(), Recovered2, Fault)
            end,
            [{sync, eio}, {write, 0, enospc}, {write, 20, enospc}, {rename, eio}]
        )
    end).

%% A server that stopped between the rename of a checkpoint and the removal
%% of the previous generation leaves files of two generations. The open
%% uses the later generation and removes the files of the earlier one.
two_generations_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, W1} = write_all([b1(), b2(), b3()], W0),
        Old = log(Dir),
        {ok, OldBin} = file:read_file(Old),
        {ok, _} = peace_storage_wal:write(snap(), W1),
        ?assertNot(filelib:is_regular(Old)),
        ok = file:write_file(Old, OldBin),
        [New] = filelib:wildcard(filename:join([Dir, "*", "*.wal"])) -- [Old],
        %% The server stopped before it created the log of the new
        %% generation.
        ok = file:delete(New),
        {_, Recovered} = open(Dir),
        ?assertEqual(s4(), Recovered),
        ?assertNot(filelib:is_regular(Old)),
        ?assert(filelib:is_regular(New))
    end).

%% ---------------------------------------------------------------------------

%% A snapshot that is larger than one chunk, at index 2.
large() -> {2, {lists:seq(1, 300), #{}, cfg}}.

open_chunked(Dir) ->
    {ok, W, Stored} = peace_storage_wal:open(?ID, #{dir => Dir, io => ?IO, checkpoint_chunk_bytes => 64}),
    {W, Stored}.

finish({more, W}) -> finish(peace_storage_wal:snapshot_continue(W));
finish({done, W}) -> W.

chunked_checkpoint_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open_chunked(Dir),
        {ok, W1} = write_all([b1(), b2(), b3()], W0),
        {ok, _} = peace_storage_wal:write(#{snapshot => large()}, W1),
        [Ckpt] = filelib:wildcard(filename:join([Dir, "*", "*.ckpt"])),
        %% The checkpoint holds the snapshot in more than one record.
        {ok, Bin} = file:read_file(Ckpt),
        ?assert(length(binary:matches(Bin, <<16#70656163:32>>)) > 3),
        {_, Recovered} = open_chunked(Dir),
        ?assertEqual(#{promised => {2, ?ID}, snapshot => large(), entries => #{3 => entry(1, c)}}, Recovered)
    end).

%% The writes that are made between the steps of a checkpoint are part of
%% the checkpoint.
writes_during_checkpoint_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open_chunked(Dir),
        {ok, W1} = write_all([b1(), b2()], W0),
        {more, W2} = peace_storage_wal:snapshot_begin(#{snapshot => large()}, W1),
        {more, W3} = peace_storage_wal:snapshot_continue(W2),
        {ok, W4} = peace_storage_wal:write(b3(), W3),
        {more, W5} = peace_storage_wal:snapshot_continue(W4),
        {ok, W6} = peace_storage_wal:write(#{entries => [{4, entry(2, d)}]}, W5),
        ?assertEqual({error, checkpoint_in_progress}, peace_storage_wal:write(snap(), W6)),
        W7 = finish({more, W6}),
        Expected = #{
            promised => {2, ?ID}, snapshot => large(), entries => #{3 => entry(1, c), 4 => entry(2, d)}
        },
        {_, Recovered} = open_chunked(Dir),
        ?assertEqual(Expected, Recovered),
        %% The store is usable after the checkpoint.
        {ok, _} = peace_storage_wal:write(#{entries => [{5, entry(2, e)}]}, W7),
        {_, #{entries := Entries}} = open_chunked(Dir),
        ?assertEqual([3, 4, 5], lists:sort(maps:keys(Entries)))
    end).

%% A server that stops during a checkpoint recovers the previous
%% generation, with the writes that were made during the checkpoint.
stop_during_checkpoint_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open_chunked(Dir),
        {ok, W1} = write_all([b1(), b2()], W0),
        {more, W2} = peace_storage_wal:snapshot_begin(#{snapshot => large()}, W1),
        {more, W3} = peace_storage_wal:snapshot_continue(W2),
        {ok, _} = peace_storage_wal:write(b3(), W3),
        {W4, Recovered} = open_chunked(Dir),
        ?assertEqual(s3(), Recovered),
        ?assertEqual([], filelib:wildcard(filename:join([Dir, "*", "*.tmp"]))),
        {ok, _} = peace_storage_wal:write(#{snapshot => large()}, W4),
        {_, #{snapshot := Snapshot}} = open_chunked(Dir),
        ?assertEqual(large(), Snapshot)
    end).

%% A checkpoint that holds the snapshot in one record was written by an
%% earlier version of the backend. `open/2' reads it.
single_record_checkpoint_test() ->
    with_dir(fun(Dir) ->
        {W0, _} = open(Dir),
        {ok, _} = write_all([b1(), b2(), b3(), snap()], W0),
        [Ckpt] = filelib:wildcard(filename:join([Dir, "*", "*.ckpt"])),
        #{snapshot := Snapshot, promised := Promised, entries := Entries} = s4(),
        Payload = term_to_binary({Promised, Snapshot, Entries}),
        Len = byte_size(Payload),
        Record = <<16#70656163:32, Len:64, (erlang:crc32([<<Len:64>>, Payload])):32, Payload/binary>>,
        ok = file:write_file(Ckpt, [<<"peacewal", 1:32>>, Record]),
        {_, Recovered} = open(Dir),
        ?assertEqual(s4(), Recovered)
    end).

open(Dir) ->
    {ok, W, Stored} = peace_storage_wal:open(?ID, #{dir => Dir, io => ?IO}),
    {W, Stored}.

write_all(Batches, W0) ->
    {ok, lists:foldl(
        fun(Batch, W) ->
            {ok, W1} = peace_storage_wal:write(Batch, W),
            W1
        end,
        W0,
        Batches
    )}.

log(Dir) ->
    [Log] = filelib:wildcard(filename:join([Dir, "*", "*.wal"])),
    Log.

flip(Bin, Pos) ->
    <<Before:Pos/binary, Byte, After/binary>> = Bin,
    <<Before/binary, (Byte bxor 16#55), After/binary>>.

with_dir(Fun) ->
    Dir = filename:join([
        filename:basedir(user_cache, "peace_tests"),
        "wal_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    try
        Fun(Dir)
    after
        peace_storage_faulty_io:disarm(),
        file:del_dir_r(Dir)
    end.
