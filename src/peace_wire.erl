%% @doc The versions of the messages between servers.
%%
%% A server handles every message version in a range `{Min, Max}'. The
%% range of this version of peace is `{?MSG_VERSION_MIN, ?MSG_VERSION}',
%% from `peace.hrl'.
%%
%% == The envelope ==
%%
%% A server sends three kinds of message to another server:
%%
%% <ul>
%% <li>`{peace_msg, Version, Range, From, To, Body}' - a message of the
%%   protocol.</li>
%% <li>`{peace_chunk, Version, Range, From, To, Body}' - a message of a
%%   snapshot transfer.</li>
%% <li>`{peace_versions, Range, From}' - an answer to a message that the
%%   server dropped because of the version of the message.</li>
%% </ul>
%%
%% `Version' is the version of `Body'. `Range' is the range of the server
%% that sent the message. The envelope is the same in every version. Only
%% `Body' depends on the version.
%%
%% == The choice of a version ==
%%
%% A server records the range of each server from which it receives an
%% envelope. The record is not stored. `choose/2' gives the version of a
%% message to a receiver:
%%
%% <ul>
%% <li>When the range of the receiver is not known, the version is the
%%   earliest version of the sender.</li>
%% <li>When the two ranges have a common version, the version is the latest
%%   common version.</li>
%% <li>When the two ranges have no common version, the version is the
%%   version of the sender that is nearest to the range of the receiver.
%%   The receiver drops the message.</li>
%% </ul>
%%
%% A server that receives a message of a version outside its range drops
%% the message and answers `peace_versions'. The sender then knows the
%% range of the receiver. This answer is needed after a server restarts
%% with an earlier version of peace, because that server may send no
%% message of the protocol.
%%
%% == A later version ==
%%
%% A version of peace that changes the messages does the following:
%%
%% <ol>
%% <li>It raises `?MSG_VERSION' by one and keeps `?MSG_VERSION_MIN'.</li>
%% <li>It adds a clause for the new version to `encode/2' and to
%%   `decode/2'. The clause of the earlier version converts between the
%%   earlier body and the terms that `peace_core' handles.</li>
%% <li>It sends nothing to a receiver that the earlier version cannot
%%   express. A message that exists only in the new version is sent to a
%%   receiver only when the version for that receiver is the new
%%   version.</li>
%% <li>If it changes the encoding of a snapshot, it starts a snapshot
%%   transfer again when the version for the receiver changes.</li>
%% </ol>
%%
%% The version of peace after that one may raise `?MSG_VERSION_MIN'.
%%
%% == Test versions ==
%%
%% A test build has versions later than `?MSG_VERSION'. The body of such a
%% version is `{peace_test_version, Version, Msg}'. A server of a test
%% build takes its range from the option `test_msg_versions'. The
%% simulation uses these versions to upgrade a cluster while it runs. See
%% `peace_dst'.
-module(peace_wire).

-include("peace.hrl").

-export([range/1, choose/2, handles/2, encode/2, decode/2]).

-export_type([version/0, range/0]).

-type version() :: pos_integer().
%% The earliest and the latest version that a server handles.
-type range() :: {version(), version()}.

%% The range of a server with the configuration `Config'.
-spec range(map()) -> range().
-ifdef(TEST).
range(Config) -> maps:get(test_msg_versions, Config, {?MSG_VERSION_MIN, ?MSG_VERSION}).
-else.
range(_Config) -> {?MSG_VERSION_MIN, ?MSG_VERSION}.
-endif.

%% The version of a message from a server with the range `Mine' to a
%% server with the range `Peer'. `Peer' is `undefined' when the range is
%% not known.
-spec choose(range(), range() | undefined) -> version().
choose({Min, _Max}, undefined) -> Min;
choose({Min, Max}, {_PeerMin, PeerMax}) -> max(Min, min(Max, PeerMax)).

%% Whether a server with the range `Range' handles the version `Version'.
-spec handles(term(), range()) -> boolean().
handles(Version, {Min, Max}) -> is_integer(Version) andalso Version >= Min andalso Version =< Max.

%% The body of the message `Msg' in the version `Version'.
-spec encode(version(), term()) -> term().
encode(?MSG_VERSION, Msg) -> Msg;
encode(Version, Msg) -> test_encode(Version, Msg).

%% The message in the body `Body' of the version `Version'.
-spec decode(version(), term()) -> {ok, term()} | error.
decode(?MSG_VERSION, Body) -> {ok, Body};
decode(Version, Body) -> test_decode(Version, Body).

-ifdef(TEST).
test_encode(Version, Msg) when Version > ?MSG_VERSION -> {peace_test_version, Version, Msg}.

test_decode(Version, {peace_test_version, Version, Msg}) when Version > ?MSG_VERSION -> {ok, Msg};
test_decode(_Version, _Body) -> error.
-else.
-spec test_encode(version(), term()) -> no_return().
test_encode(Version, _Msg) -> error({message_version, Version}).

test_decode(_Version, _Body) -> error.
-endif.
