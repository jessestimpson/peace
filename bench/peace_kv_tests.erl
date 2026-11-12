%% Tests for `peace_kv'. The first test calls the machine directly. The
%% second test runs the client against three servers on one node.
-module(peace_kv_tests).

-include_lib("eunit/include/eunit.hrl").

apply_test() ->
    Meta = #{index => 1},
    S0 = peace_kv:init([]),
    ?assertEqual({S0, not_found}, peace_kv:apply(Meta, {get, k}, S0)),
    ?assertEqual({S0, {error, not_found}}, peace_kv:apply(Meta, {cas, k, 1, 2}, S0)),
    {S1, ok} = peace_kv:apply(Meta, {put, k, 1}, S0),
    ?assertEqual({S1, {ok, 1}}, peace_kv:apply(Meta, {get, k}, S1)),
    ?assertEqual({S1, {error, {mismatch, 1}}}, peace_kv:apply(Meta, {cas, k, 0, 2}, S1)),
    {S2, ok} = peace_kv:apply(Meta, {cas, k, 1, 2}, S1),
    ?assertEqual({S2, {ok, 2}}, peace_kv:apply(Meta, {get, k}, S2)),
    {S3, ok} = peace_kv:apply(Meta, {delete, k}, S2),
    ?assertEqual(S0, S3),
    %% Deleting an absent key is not an error.
    ?assertEqual({S0, ok}, peace_kv:apply(Meta, {delete, k}, S0)).

cluster_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(peace) end, fun(_) -> application:stop(peace) end,
        {timeout, 30, fun cluster/0}}.

cluster() ->
    Tag = erlang:unique_integer([positive]),
    Ids = [{list_to_atom(lists:concat([peace_kv_t, Tag, "_", N])), node()} || N <- lists:seq(1, 3)],
    Opts = #{election_timeout_ms => 100, read_lease_ms => 100},
    {ok, Ids, []} = peace:start_cluster(Ids, peace_kv:machine(), Opts),
    ok = peace:trigger_election(hd(Ids)),
    {ok, ok, Leader} = retry(fun() -> peace_kv:put(Ids, a, 1, 1000) end),
    ?assertMatch({ok, {ok, 1}, Leader}, peace_kv:get(Ids, a, 1000)),
    ?assertMatch({ok, {ok, 1}, Leader}, peace_kv:read(Ids, a, 1000)),
    ?assertMatch({ok, not_found, Leader}, peace_kv:read(Ids, b, 1000)),
    ?assertMatch({ok, {error, {mismatch, 1}}, Leader}, peace_kv:cas(Ids, a, 0, 2, 1000)),
    ?assertMatch({ok, ok, Leader}, peace_kv:cas(Ids, a, 1, 2, 1000)),
    ?assertMatch({ok, {ok, 2}, Leader}, peace_kv:stale_read(Leader, a, 1000)),
    %% A session makes a retried put safe.
    Session = #{session => {client, 1}, timeout => 1000},
    ?assertMatch({ok, ok, Leader}, peace_kv:put(Ids, a, 3, Session)),
    ?assertMatch({ok, ok, Leader}, peace_kv:put(Ids, a, 3, Session)),
    ?assertMatch({ok, ok, Leader}, peace_kv:delete(Ids, a, 1000)),
    ?assertMatch({ok, not_found, Leader}, peace_kv:get(Ids, a, 1000)).

retry(Fun) ->
    retry(Fun, 50).

retry(Fun, 0) ->
    Fun();
retry(Fun, N) ->
    case Fun() of
        {ok, _, _} = Ok ->
            Ok;
        _ ->
            timer:sleep(50),
            retry(Fun, N - 1)
    end.
