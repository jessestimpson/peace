%% Tests for the functions of `peace_server' that combine the effects of a
%% group of events.
-module(peace_server_tests).

-include_lib("eunit/include/eunit.hrl").

-define(E, {1, a}).

%% Consecutive proposals to one peer become one message.
coalesce_proposals_test() ->
    Effects = [
        {send, b, {propose, ?E, [{1, x}], 0, 10}},
        {send, c, {propose, ?E, [{1, x}], 0, 10}},
        {reply, from, ok},
        {send, b, {propose, ?E, [{2, y}], 1, 11}},
        {send, c, {propose, ?E, [{2, y}], 1, 11}}
    ],
    ?assertEqual(
        [
            {reply, from, ok},
            {send, b, {propose, ?E, [{1, x}, {2, y}], 1, 11}},
            {send, c, {propose, ?E, [{1, x}, {2, y}], 1, 11}}
        ],
        peace_server:coalesce(Effects)
    ).

%% Consecutive accepts to one peer become one message with the latest clock
%% reading.
coalesce_accepts_test() ->
    Effects = [
        {send, a, {accept, ?E, [1], 10}},
        {send, a, {accept, ?E, [2, 3], 12}},
        {send, a, {accept, ?E, [], 11}}
    ],
    ?assertEqual([{send, a, {accept, ?E, [1, 2, 3], 12}}], peace_server:coalesce(Effects)).

%% Messages of different epochs are not combined. A message of another kind
%% to the same peer ends the message that is being built, and the order of
%% the messages to that peer is kept.
coalesce_keeps_order_test() ->
    Effects = [
        {send, b, {propose, ?E, [{1, x}], 0, 10}},
        {send, b, {propose, {2, a}, [{1, x}], 0, 11}},
        {send, b, {accept, {2, a}, [4], 12}},
        {send, b, {catchup, 5}},
        {send, b, {accept, {2, a}, [5], 13}}
    ],
    ?assertEqual(Effects, peace_server:coalesce(Effects)).

%% Only the last effect on each timer is kept.
coalesce_timers_test() ->
    Effects = [
        {timer, election, reset},
        {timer, heartbeat, reset},
        {reply, from, ok},
        {timer, election, cancel},
        {timer, election, reset},
        {timer, heartbeat, cancel}
    ],
    ?assertEqual(
        [{reply, from, ok}, {timer, election, reset}, {timer, heartbeat, cancel}],
        peace_server:coalesce(Effects)
    ).

%% A later batch overrides an earlier batch, index by index.
merge_overrides_test() ->
    Batches = [
        #{entries => [{1, {?E, x}}, {2, {?E, y}}]},
        #{entries => [{2, {{2, b}, z}}, {3, {{2, b}, w}}]}
    ],
    ?assertEqual(
        {#{entries => [{1, {?E, x}}, {2, {{2, b}, z}}, {3, {{2, b}, w}}]}, true},
        peace_server:merge_batches(Batches)
    ).

%% A snapshot removes the entries that it covers. A write with a snapshot or
%% with `promised' is performed before every other effect.
merge_snapshot_test() ->
    Batches = [#{snapshot => {2, snap}}, #{entries => [{2, {learned, y}}, {3, {?E, z}}]}],
    ?assertEqual(
        {#{snapshot => {2, snap}, entries => [{3, {?E, z}}]}, false},
        peace_server:merge_batches(Batches)
    ),
    ?assertEqual(
        {#{promised => ?E, entries => [{1, {?E, x}}]}, false},
        peace_server:merge_batches([#{promised => ?E}, #{entries => [{1, {?E, x}}]}])
    ).

%% A write that contains only `learned' entries is not synced.
merge_learned_only_test() ->
    ?assertEqual(
        {#{entries => [{1, {learned, x}}, {2, {learned, y}}], sync => false}, true},
        peace_server:merge_batches([#{entries => [{1, {learned, x}}]}, #{entries => [{2, {learned, y}}]}])
    ),
    ?assertEqual({#{}, true}, peace_server:merge_batches([])).

%% An index that is proposed and decided in the same group was decided on
%% the acceptance of this server alone. The write is performed first and is
%% synced.
merge_proposed_and_decided_test() ->
    Batches = [#{entries => [{1, {?E, x}}]}, #{entries => [{1, {learned, x}}]}],
    ?assertEqual(
        {#{entries => [{1, {learned, x}}]}, false},
        peace_server:merge_batches(Batches)
    ).
