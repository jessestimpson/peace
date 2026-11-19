-module(peace_wire_tests).

-include_lib("eunit/include/eunit.hrl").
-include("peace.hrl").

range_test() ->
    ?assertEqual({?MSG_VERSION_MIN, ?MSG_VERSION}, peace_wire:range(#{})),
    ?assertEqual({2, 3}, peace_wire:range(#{test_msg_versions => {2, 3}})).

%% Each row: the range of the sender, the range of the receiver and the
%% version that the sender chooses.
choose_test_() ->
    [
        ?_assertEqual(Version, peace_wire:choose(Mine, Peer))
     || {Mine, Peer, Version} <- [
            %% The range of the receiver is not known.
            {{1, 1}, undefined, 1},
            {{2, 3}, undefined, 2},
            %% The ranges have a common version.
            {{1, 1}, {1, 1}, 1},
            {{1, 2}, {1, 1}, 1},
            {{1, 1}, {1, 2}, 1},
            {{1, 2}, {1, 2}, 2},
            {{1, 2}, {2, 3}, 2},
            {{2, 3}, {1, 2}, 2},
            {{1, 3}, {2, 5}, 3},
            %% The ranges have no common version.
            {{1, 1}, {2, 3}, 1},
            {{2, 3}, {1, 1}, 2},
            {{3, 4}, {1, 2}, 3}
        ]
    ].

handles_test() ->
    ?assert(peace_wire:handles(2, {2, 3})),
    ?assert(peace_wire:handles(3, {2, 3})),
    ?assertNot(peace_wire:handles(1, {2, 3})),
    ?assertNot(peace_wire:handles(4, {2, 3})),
    ?assertNot(peace_wire:handles(two, {2, 3})).

%% The body of the present version is the message. The body of a test
%% version is not the message, and a body is decoded only as its own
%% version.
encode_and_decode_test() ->
    Msg = {prepare, {1, a}, 0},
    ?assertEqual(Msg, peace_wire:encode(?MSG_VERSION, Msg)),
    ?assertEqual({ok, Msg}, peace_wire:decode(?MSG_VERSION, Msg)),
    Later = ?MSG_VERSION + 1,
    Body = peace_wire:encode(Later, Msg),
    ?assertNotEqual(Msg, Body),
    ?assertEqual({ok, Msg}, peace_wire:decode(Later, Body)),
    ?assertEqual(error, peace_wire:decode(Later + 1, Body)),
    ?assertEqual(error, peace_wire:decode(Later, Msg)).
