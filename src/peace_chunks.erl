%% @doc Encodes a term into chunks of a fixed size.
%%
%% `peace_transfer' sends a snapshot in chunks, and `peace_storage_wal'
%% writes a snapshot in chunks. Both use this module to encode the snapshot.
%%
%% `term_to_binary/1' returns the encoding as one binary. The emulator
%% allocates that binary in one piece. On the computer of the benchmark, the
%% allocation of a binary of 1000 MB stops every process of the node for 30
%% to 70 ms (measured on 2026-11-13, Erlang/OTP 28, Apple M4). This module
%% uses `erlang:term_to_iovec/1' instead. The result is a list of binaries.
%% A binary of more than 64 bytes inside the term is not copied: the list
%% holds a reference to it.
%%
%% == Limitations ==
%%
%% <ul>
%% <li>The parts of the term that are not binaries of more than 64 bytes are
%%   encoded into new binaries, and this module does not control the size
%%   of those binaries.</li>
%% <li>`decode/1' joins the chunks into one binary. The decoded term refers
%%   to that binary.</li>
%% </ul>
-module(peace_chunks).

-export([encode/2, crc/1, decode/1]).

%% @doc Encodes `Term'. Returns the chunks in order and the number of bytes
%% of the encoding. Every chunk except the last chunk holds `Bytes' bytes.
-spec encode(term(), pos_integer()) -> {[iodata()], non_neg_integer()}.
encode(Term, Bytes) ->
    Iovec = erlang:term_to_iovec(Term),
    {split(Iovec, Bytes, Bytes, [], []), iolist_size(Iovec)}.

%% @doc The CRC of an encoding.
-spec crc([iodata()]) -> non_neg_integer().
crc(Chunks) ->
    erlang:crc32(Chunks).

%% @doc Decodes the chunks of an encoding, in order. Fails with `badarg' if
%% the chunks are not an encoding.
-spec decode([iodata()]) -> term().
decode(Chunks) ->
    binary_to_term(iolist_to_binary(Chunks)).

%% `Room' is the number of bytes that the chunk that is being built can
%% still take. `Parts' holds the binaries of that chunk in reverse order.
split([], _Bytes, _Room, [], Chunks) ->
    lists:reverse(Chunks);
split([], _Bytes, _Room, Parts, Chunks) ->
    lists:reverse([lists:reverse(Parts) | Chunks]);
split([Bin | Rest], Bytes, Room, Parts, Chunks) ->
    case byte_size(Bin) of
        0 ->
            split(Rest, Bytes, Room, Parts, Chunks);
        Size when Size < Room ->
            split(Rest, Bytes, Room - Size, [Bin | Parts], Chunks);
        Size when Size =:= Room ->
            split(Rest, Bytes, Bytes, [], [lists:reverse([Bin | Parts]) | Chunks]);
        _Size ->
            <<Head:Room/binary, Tail/binary>> = Bin,
            split([Tail | Rest], Bytes, Bytes, [], [lists:reverse([Head | Parts]) | Chunks])
    end.
