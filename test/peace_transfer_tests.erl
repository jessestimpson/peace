-module(peace_transfer_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, {a, n}).
-define(B, {b, n}).
-define(C, {c, n}).
-define(RETRY, 50).

snapshot() ->
    {lists:seq(1, 200), #{}, config}.

new(Bytes) ->
    peace_transfer:new(Bytes, ?RETRY).

%% Starts a sender that holds the encoded snapshot as of `Index' and has
%% offered the snapshot to `Peer'.
sender(Peer, Index, Bytes) ->
    {T0, encode} = peace_transfer:offer(Peer, Index, 0, new(Bytes)),
    {Chunks, Size} = peace_chunks:encode(snapshot(), Bytes),
    {T, [{send, Peer, Offer}]} = peace_transfer:encoded(Index, Chunks, Size, peace_chunks:crc(Chunks), T0),
    {T, Offer}.

%% Delivers messages between the sender `?A' and the receiver `?B' until no
%% message is left. The commit index of the receiver is 0 and the clock
%% reading is 0. Returns both states and the `install' message.
run(Sender, Receiver, Msgs) ->
    run(Sender, Receiver, Msgs, none).

run(Sender, Receiver, [], Install) ->
    {Sender, Receiver, Install};
run(Sender, Receiver0, [{offer, Id} | Msgs], Install) ->
    {Receiver, Sends} = peace_transfer:offered(?A, Id, 0, 0, Receiver0),
    run(Sender, Receiver, Msgs ++ [M || {send, ?A, M} <- Sends], Install);
run(Sender, Receiver0, [{chunk, Id, Offset, Bin} | Msgs], Install0) ->
    {Receiver, Sends, Install} = peace_transfer:chunk(?A, Id, Offset, Bin, 0, Receiver0),
    run(Sender, Receiver, Msgs ++ [M || {send, ?A, M} <- Sends], first(Install0, Install));
run(Sender0, Receiver, [{request, Id, Offset} | Msgs], Install) ->
    {Sender, Sends} = peace_transfer:request(?B, Id, Offset, Sender0),
    run(Sender, Receiver, Msgs ++ [M || {send, ?B, M} <- Sends], Install).

first(none, Install) -> Install;
first(Install, none) -> Install.

transfers_in_chunks_test() ->
    {Sender, Offer = {offer, Id}} = sender(?B, 7, 100),
    ?assertMatch({_, [{send, ?B, {chunk, Id, 0, <<_:100/binary>>}}]}, peace_transfer:request(?B, Id, 0, Sender)),
    {_, _, Install} = run(Sender, new(100), [Offer]),
    ?assertEqual({install, 7, snapshot()}, Install).

one_chunk_test() ->
    {Sender, Offer} = sender(?B, 7, 1 bsl 20),
    {_, _, Install} = run(Sender, new(100), [Offer]),
    ?assertEqual({install, 7, snapshot()}, Install).

%% The sender does not encode again while its log holds the entries above
%% the encoded snapshot.
sender_reuses_encoded_snapshot_test() ->
    {Sender0, Offer} = sender(?B, 7, 100),
    ?assertMatch({_, {send, ?B, Offer}}, peace_transfer:offer(?B, 9, 7, Sender0)),
    ?assertMatch({_, {send, ?C, Offer}}, peace_transfer:offer(?C, 9, 0, Sender0)),
    ?assertMatch({_, encode}, peace_transfer:offer(?B, 9, 8, Sender0)).

offers_during_encoding_wait_test() ->
    {T0, encode} = peace_transfer:offer(?B, 7, 0, new(100)),
    {T1, none} = peace_transfer:offer(?C, 8, 0, T0),
    {Chunks, Size} = peace_chunks:encode(snapshot(), 100),
    {_, Sends} = peace_transfer:encoded(7, Chunks, Size, peace_chunks:crc(Chunks), T1),
    ?assertMatch([{send, ?B, {offer, Id}}, {send, ?C, {offer, Id}}], Sends),
    ?assertMatch({_, encode}, peace_transfer:offer(?B, 7, 0, peace_transfer:encode_failed(T1))).

sender_discards_after_last_request_test() ->
    {Sender0, Offer} = sender(?B, 7, 100),
    {Sender, _, {install, 7, _}} = run(Sender0, new(100), [Offer]),
    ?assertMatch({_, encode}, peace_transfer:offer(?B, 7, 0, Sender)).

%% An offer of a snapshot that is not above the commit index is ignored.
offer_below_commit_test() ->
    {_, {offer, Id}} = sender(?B, 7, 100),
    T = new(100),
    ?assertEqual({T, []}, peace_transfer:offered(?A, Id, 7, 0, T)),
    ?assertMatch({_, [{send, ?A, {request, Id, 0}}]}, peace_transfer:offered(?A, Id, 6, 0, T)).

%% A request is lost. The receiver asks again when an offer arrives and no
%% chunk arrived for the retry time.
receiver_asks_again_test() ->
    {Sender, Offer = {offer, Id}} = sender(?B, 7, 100),
    {R1, [{send, ?A, {request, Id, 0}}]} = peace_transfer:offered(?A, Id, 0, 0, new(100)),
    ?assertEqual({R1, []}, peace_transfer:offered(?A, Id, 0, ?RETRY - 1, R1)),
    {R2, [{send, ?A, Again = {request, Id, 0}}]} = peace_transfer:offered(?A, Id, 0, ?RETRY, R1),
    %% The retry time starts again.
    ?assertEqual({R2, []}, peace_transfer:offered(?A, Id, 0, ?RETRY + 1, R2)),
    ?assertMatch({_, _, {install, 7, _}}, run(Sender, R2, [Again])),
    %% A chunk that arrives twice is used once.
    ?assertMatch({_, _, {install, 7, _}}, run(Sender, R2, [Again, Again, Offer])).

%% An offer of a transfer with a higher index replaces the transfer that is
%% being received. An offer of a transfer with a lower index replaces a
%% transfer only if no chunk arrived for the retry time.
receiver_replaces_transfer_test() ->
    {_, {offer, Id7}} = sender(?B, 7, 100),
    {Sender9, Offer9 = {offer, Id9}} = sender(?B, 9, 100),
    {R1, _} = peace_transfer:offered(?A, Id7, 0, 0, new(100)),
    ?assertMatch({_, _, {install, 9, _}}, run(Sender9, R1, [Offer9])),
    {R2, _} = peace_transfer:offered(?A, Id9, 0, 0, new(100)),
    ?assertEqual({R2, []}, peace_transfer:offered(?C, Id7, 0, ?RETRY - 1, R2)),
    ?assertMatch({_, [{send, ?C, {request, Id7, 0}}]}, peace_transfer:offered(?C, Id7, 0, ?RETRY, R2)).

%% Bytes that do not have the announced CRC are discarded.
damaged_chunk_test() ->
    {_, {offer, Id = {_Index, Size, _Crc}}} = sender(?B, 7, 1 bsl 20),
    {R1, _} = peace_transfer:offered(?A, Id, 0, 0, new(100)),
    {R2, [], none} = peace_transfer:chunk(?A, Id, 0, binary:copy(<<0>>, Size), 0, R1),
    %% The receiver can start again.
    ?assertMatch({_, [{send, ?A, {request, Id, 0}}]}, peace_transfer:offered(?A, Id, 0, 0, R2)).

unknown_messages_are_ignored_test() ->
    T = new(100),
    ?assertEqual({T, []}, peace_transfer:request(?B, {7, 10, 0}, 0, T)),
    ?assertEqual({T, [], none}, peace_transfer:chunk(?A, {7, 10, 0}, 5, <<"x">>, 0, T)),
    ?assertEqual({T, []}, peace_transfer:encoded(7, [<<"x">>], 1, 0, T)),
    {Sender, {offer, Id}} = sender(?B, 7, 100),
    %% An offset that is not the start of a chunk.
    ?assertEqual({Sender, []}, peace_transfer:request(?B, Id, 50, Sender)).

%% Every chunk except the last chunk has the requested size, and the chunks
%% decode to the term.
chunks_test() ->
    Term = {lists:seq(1, 100), binary:copy(<<"x">>, 1000), #{a => binary:copy(<<"y">>, 10)}},
    lists:foreach(
        fun(Bytes) ->
            {Chunks, Size} = peace_chunks:encode(Term, Bytes),
            Sizes = [iolist_size(C) || C <- Chunks],
            ?assertEqual(Size, lists:sum(Sizes)),
            ?assert(lists:all(fun(S) -> S =:= Bytes end, lists:droplast(Sizes))),
            ?assert(lists:last(Sizes) =< Bytes andalso lists:last(Sizes) > 0),
            ?assertEqual(erlang:crc32(term_to_binary(Term)), peace_chunks:crc(Chunks)),
            ?assertEqual(Term, peace_chunks:decode(Chunks))
        end,
        [1, 7, 64, 1000, 1 bsl 20]
    ),
    ?assertError(badarg, peace_chunks:decode([<<"not an encoding">>])).
