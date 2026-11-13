%% @doc The transfer of a snapshot from one server to another server, in
%% chunks.
%%
%% `peace_core' sends a snapshot as one message, `{install, Index,
%% Snapshot}'. `peace_server' does not put that message on the network. A
%% process that sends a large message through Erlang distribution is
%% suspended until the distribution buffer has room, and the messages that
%% the process sends afterwards wait behind the large message. A leader
%% that sent a large snapshot as one message would therefore delay its
%% heartbeats. `peace_server' sends the snapshot in the following way
%% instead.
%%
%% <ol>
%% <li>The sender encodes the snapshot into chunks, in a separate process
%%   (see `peace_server' and `peace_chunks'). A chunk holds at most
%%   `snapshot_chunk_bytes' bytes.</li>
%% <li>The sender sends an `offer' message. The message holds the identity
%%   of the transfer and no data.</li>
%% <li>The receiver asks for the chunk at offset 0 with a `request'
%%   message.</li>
%% <li>The sender answers each request with one `chunk' message. At most
%%   one chunk per receiver is on the network.</li>
%% <li>The receiver stores the chunk and asks for the chunk at the next
%%   offset.</li>
%% <li>The receiver decodes the chunks after the last chunk and gives the
%%   `install' message to `peace_core'.</li>
%% </ol>
%%
%% This module is the state of the transfers of one server, as a pure
%% function. `peace_server' sends the messages and starts the encoding.
%%
%% == Identity ==
%%
%% A transfer is identified by the index of the snapshot, the size of the
%% encoding and the CRC of the encoding. A sender that encodes the same
%% index twice may produce two different encodings. The identity prevents a
%% receiver from joining chunks of two encodings.
%%
%% == The sender ==
%%
%% The sender keeps one encoded snapshot. A receiver that is behind asks
%% `peace_core' for the missing entries each time it receives a proposal,
%% and `peace_core' answers with an `install' message every time. `offer/4'
%% handles each of these messages.
%%
%% <ul>
%% <li>If the sender holds no encoded snapshot, the sender encodes the
%%   snapshot of the message.</li>
%% <li>If the sender holds an encoded snapshot, and the log of the sender
%%   still holds every entry above the index of that snapshot, the sender
%%   offers that snapshot again. A transfer is therefore not started again
%%   for each `install' message.</li>
%% <li>Otherwise the receiver could not continue from the encoded snapshot,
%%   and the sender encodes the snapshot of the message.</li>
%% </ul>
%%
%% The sender discards the encoded snapshot when every receiver has asked
%% for the last chunk.
%%
%% == The receiver ==
%%
%% The receiver receives one transfer at a time. `offered/5' handles an
%% `offer' message.
%%
%% <ul>
%% <li>The receiver ignores an offer of a snapshot that is not above its
%%   commit index.</li>
%% <li>If the receiver receives no transfer, it starts the transfer that is
%%   offered.</li>
%% <li>If the offer is for another transfer than the transfer that the
%%   receiver receives, the receiver starts the offered transfer in two
%%   cases: the offered snapshot has a higher index, or no chunk arrived
%%   for the retry time.</li>
%% </ul>
%%
%% == Lost messages ==
%%
%% A message is lost when the connection between two nodes closes. If the
%% receiver receives an offer for the transfer that it receives, and no
%% chunk arrived for the retry time, the receiver asks again for the chunk
%% that it needs. `peace_server' sets the retry time to the election
%% timeout. If the sender no longer holds the encoded snapshot, the sender
%% does not answer. The sender then offers another transfer, and the
%% receiver starts that transfer by the rules above.
%%
%% == Limitations ==
%%
%% <ul>
%% <li>The sender holds the whole encoded snapshot in memory. The encoding
%%   refers to the binaries of more than 64 bytes in the snapshot and does
%%   not copy them (see `peace_chunks').</li>
%% <li>The receiver holds the chunks in memory. To decode, the receiver
%%   joins the chunks into one binary, in the server process. The
%%   allocation of a large binary stops every process of the node for a
%%   time that grows with the size (see `peace_chunks').</li>
%% <li>If a receiver stops during a transfer, the sender keeps the encoded
%%   snapshot until the sender needs a newer one.</li>
%% <li>One chunk is sent per request. The rate of a transfer is at most one
%%   chunk per network round trip.</li>
%% </ul>
-module(peace_transfer).

-export([new/2, chunk_bytes/1, offer/4, encoded/5, encode_failed/1, request/4, offered/5, chunk/6]).
-export_type([t/0, msg/0, id/0]).

-type peer() :: peace:server_id().

%% The index of the snapshot, the size of the encoding in bytes, and the
%% CRC of the encoding.
-type id() :: {peace:index(), non_neg_integer(), non_neg_integer()}.

-type msg() ::
    {offer, id()}
    | {request, id(), Offset :: non_neg_integer()}
    | {chunk, id(), Offset :: non_neg_integer(), binary()}.

-record(out, {
    id :: id(),
    %% The chunks of the encoding. Every chunk except the last chunk holds
    %% `chunk_bytes' bytes.
    chunks :: tuple(),
    %% The receivers that have not asked for the last chunk.
    readers :: [peer()]
}).

-record(in, {
    peer :: peer(),
    id :: id(),
    %% The chunks that were received, in reverse order.
    chunks = [] :: [binary()],
    %% The number of bytes that were received.
    offset = 0 :: non_neg_integer(),
    %% The CRC of the bytes that were received.
    crc = erlang:crc32(<<>>) :: non_neg_integer(),
    %% The clock reading when the last request was sent.
    asked :: integer()
}).

-record(transfer, {
    chunk_bytes :: pos_integer(),
    retry_ms :: pos_integer(),
    out :: undefined | {encoding, peace:index(), [peer()]} | #out{},
    in :: undefined | #in{}
}).

-opaque t() :: #transfer{}.

%% @doc `ChunkBytes' is the size of a chunk. `RetryMs' is the retry time.
%% See "Lost messages" in the module documentation.
-spec new(pos_integer(), pos_integer()) -> t().
new(ChunkBytes, RetryMs) ->
    #transfer{chunk_bytes = ChunkBytes, retry_ms = RetryMs}.

%% @doc The size of a chunk in bytes.
-spec chunk_bytes(t()) -> pos_integer().
chunk_bytes(#transfer{chunk_bytes = Bytes}) ->
    Bytes.

%% ---------------------------------------------------------------------------
%% The sender
%% ---------------------------------------------------------------------------

%% @doc `peace_core' sent a snapshot as of `Index' to `Peer'. `Floor' is
%% the snapshot index of this server: the log holds the entries above
%% `Floor'.
%%
%% The result `encode' means that the caller must encode the snapshot and
%% call `encoded/5'.
-spec offer(peer(), peace:index(), peace:index(), t()) -> {t(), encode | none | {send, peer(), msg()}}.
offer(Peer, _Index, Floor, T = #transfer{out = Out = #out{id = Id = {Cached, _, _}, readers = Readers}}) when
    Cached >= Floor
->
    {T#transfer{out = Out#out{readers = lists:usort([Peer | Readers])}}, {send, Peer, {offer, Id}}};
offer(Peer, _Index, _Floor, T = #transfer{out = {encoding, Encoding, Peers}}) ->
    {T#transfer{out = {encoding, Encoding, lists:usort([Peer | Peers])}}, none};
offer(Peer, Index, _Floor, T) ->
    {T#transfer{out = {encoding, Index, [Peer]}}, encode}.

%% @doc The snapshot as of `Index' was encoded with
%% `peace_chunks:encode/2'. Returns the offer for each receiver that waits.
-spec encoded(peace:index(), [iodata()], non_neg_integer(), non_neg_integer(), t()) ->
    {t(), [{send, peer(), msg()}]}.
encoded(Index, Chunks, Size, Crc, T = #transfer{out = {encoding, Index, Peers}}) ->
    Id = {Index, Size, Crc},
    {T#transfer{out = #out{id = Id, chunks = list_to_tuple(Chunks), readers = Peers}}, [
        {send, Peer, {offer, Id}}
     || Peer <- Peers
    ]};
encoded(_Index, _Chunks, _Size, _Crc, T) ->
    {T, []}.

%% @doc The encoding failed. A later `offer/4' starts the encoding again.
-spec encode_failed(t()) -> t().
encode_failed(T = #transfer{out = {encoding, _Index, _Peers}}) ->
    T#transfer{out = undefined};
encode_failed(T) ->
    T.

%% @doc `Peer' asked for the chunk at `Offset' of the transfer `Id'.
-spec request(peer(), id(), non_neg_integer(), t()) -> {t(), [{send, peer(), msg()}]}.
request(
    Peer,
    Id = {_Index, Size, _Crc},
    Offset,
    T = #transfer{out = Out = #out{id = Id, chunks = Chunks}, chunk_bytes = Bytes}
) when
    Offset < Size, Offset rem Bytes =:= 0
->
    Send = {send, Peer, {chunk, Id, Offset, iolist_to_binary(element(Offset div Bytes + 1, Chunks))}},
    case Offset + Bytes >= Size of
        true ->
            case lists:delete(Peer, Out#out.readers) of
                [] -> {T#transfer{out = undefined}, [Send]};
                Readers -> {T#transfer{out = Out#out{readers = Readers}}, [Send]}
            end;
        false ->
            {T, [Send]}
    end;
request(_Peer, _Id, _Offset, T) ->
    {T, []}.

%% ---------------------------------------------------------------------------
%% The receiver
%% ---------------------------------------------------------------------------

%% @doc `Peer' offered the transfer `Id'. `Commit' is the commit index of
%% this server, and `Now' is the clock reading in milliseconds.
-spec offered(peer(), id(), peace:index(), integer(), t()) -> {t(), [{send, peer(), msg()}]}.
offered(_Peer, {Index, _Size, _Crc}, Commit, _Now, T) when Index =< Commit ->
    {T, []};
offered(Peer, Id, _Commit, Now, T = #transfer{in = undefined}) ->
    start(Peer, Id, Now, T);
offered(Peer, Id, _Commit, Now, T = #transfer{in = In = #in{peer = Peer, id = Id}, retry_ms = RetryMs}) ->
    case Now - In#in.asked >= RetryMs of
        true -> {T#transfer{in = In#in{asked = Now}}, [{send, Peer, {request, Id, In#in.offset}}]};
        false -> {T, []}
    end;
offered(Peer, Id = {Index, _, _}, _Commit, Now, T = #transfer{in = In, retry_ms = RetryMs}) ->
    #in{id = {Receiving, _, _}, asked = Asked} = In,
    case Index > Receiving orelse Now - Asked >= RetryMs of
        true -> start(Peer, Id, Now, T);
        false -> {T, []}
    end.

%% @doc A chunk arrived from `Peer'. The third element of the result is the
%% `install' message for `peace_core', after the last chunk.
-spec chunk(peer(), id(), non_neg_integer(), binary(), integer(), t()) ->
    {t(), [{send, peer(), msg()}], none | {install, peace:index(), peace_core:snapshot()}}.
chunk(Peer, Id, Offset, Bin, Now, T = #transfer{in = In = #in{peer = Peer, id = Id, offset = Offset}}) when
    byte_size(Bin) > 0
->
    accept(
        In#in{
            chunks = [Bin | In#in.chunks],
            offset = Offset + byte_size(Bin),
            crc = erlang:crc32(In#in.crc, Bin),
            asked = Now
        },
        T
    );
chunk(_Peer, _Id, _Offset, _Bin, _Now, T) ->
    %% A chunk of another transfer, or a chunk that arrived twice.
    {T, [], none}.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

start(Peer, Id, Now, T) ->
    {T#transfer{in = #in{peer = Peer, id = Id, asked = Now}}, [{send, Peer, {request, Id, 0}}]}.

accept(In = #in{peer = Peer, id = Id = {_Index, Size, _Crc}, offset = Offset}, T) when Offset < Size ->
    {T#transfer{in = In}, [{send, Peer, {request, Id, Offset}}], none};
accept(#in{id = {Index, Size, Crc}, offset = Size, crc = Crc, chunks = Chunks}, T) ->
    Install =
        try peace_chunks:decode(lists:reverse(Chunks)) of
            Snapshot -> {install, Index, Snapshot}
        catch
            error:badarg -> none
        end,
    {T#transfer{in = undefined}, [], Install};
accept(_In, T) ->
    %% The bytes are not the bytes that the sender announced.
    {T#transfer{in = undefined}, [], none}.
