%% The whole thing with real processes, on one node.
-module(peace_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_MACHINE, {module, peace_test_machine, #{}}).
-define(FAST, fast()).

peace_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun values_and_queries/1,
        fun leader_failover/1,
        fun flexible_quorum_survives_what_majority_cannot/1,
        fun durable_restart/1,
        fun sessions_snapshots_and_leases/1,
        fun change_members/1,
        fun machine_effects/1,
        fun unsafe_quorum_is_refused/1
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(peace),
    %% Names are per test so a slow shutdown cannot collide with the next one.
    Tag = erlang:unique_integer([positive]),
    [{list_to_atom(lists:concat([peace_t, Tag, "_", N])), node()} || N <- lists:seq(1, 5)].

teardown(_Ids) ->
    ok = application:stop(peace).

values_and_queries(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, ?FAST),
        Leader = await_leader(Ids),
        {ok, ok, Leader} = peace:propose(Ids, {put, a, 1}),
        %% Any member will do: the request follows the redirect.
        [Follower | _] = Ids -- [Leader],
        {ok, 1, Leader} = peace:propose(Follower, {get, a}),
        {ok, #{a := 1}, Leader} = peace:consistent_query(Follower, fun(#{kv := KV}) -> KV end),
        {ok, Ids, Leader} = peace:members(Leader),
        ok = peace:propose_async(Leader, {put, b, 2}),
        {ok, 2, Leader} = peace:propose(Leader, {get, b}),
        %% Followers converge on the same history.
        Histories = await(fun() ->
            Hs = [history(Id) || Id <- Ids],
            case lists:usort(Hs) of
                [H] when length(H) =:= 4 -> {ok, H};
                _ -> retry
            end
        end),
        ?assertMatch([{_, {put, a, 1}}, {_, {get, a}}, {_, {put, b, 2}}, {_, {get, b}}], Histories),
        #{role := leader, commit_index := Commit} = peace:overview(Leader),
        ?assert(Commit >= 4)
    end).

leader_failover(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, ?FAST),
        Leader = await_leader(Ids),
        {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
        ok = peace:stop_server(Leader),
        Rest = Ids -- [Leader],
        NewLeader = await_leader(Rest),
        ?assertNotEqual(Leader, NewLeader),
        %% What was acknowledged is still there.
        {ok, 1, NewLeader} = peace:propose(Rest, {get, a}),
        %% One more down leaves no majority, and nothing is acknowledged.
        [Last] = Rest -- [NewLeader],
        ok = peace:stop_server(NewLeader),
        ?assertMatch(
            Result when element(1, Result) =/= ok,
            peace:propose(Last, {put, a, 2}, 500)
        )
    end).

%% Five members, {counting, 4, 2}: values commit with three members down,
%% which a majority system cannot do. The price is at election time.
flexible_quorum_survives_what_majority_cannot(Ids) ->
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, (fast())#{quorum => {counting, 4, 2}}),
        Leader = await_leader(Ids),
        [F1, F2, F3, F4] = Ids -- [Leader],
        [ok = peace:stop_server(F) || F <- [F2, F3, F4]],
        {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
        {ok, 1, Leader} = peace:propose(F1, {get, a}),
        %% With the leader gone too, one member is nowhere near four promises.
        ok = peace:stop_server(Leader),
        timer:sleep(400),
        ?assertMatch(#{role := Role} when Role =/= leader, peace:overview(F1))
    end).

durable_restart(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    Dir = filename:join([
        filename:basedir(user_cache, "peace_tests"),
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    Opts = (fast())#{storage => {peace_storage_dets, #{dir => Dir}}},
    Config = fun(Id) -> Opts#{id => Id, members => Ids, machine => ?TEST_MACHINE} end,
    {setup, fun() -> ok end, fun(_) -> file:del_dir_r(Dir) end,
        ?_test(begin
            {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, Opts),
            Leader = await_leader(Ids),
            {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
            %% The whole cluster goes down and comes back.
            [ok = peace:stop_server(Id) || Id <- Ids],
            [ok = peace:start_server(Config(Id)) || Id <- Ids],
            NewLeader = await_leader(Ids),
            {ok, 1, NewLeader} = peace:propose(NewLeader, {get, a}),
            %% Epochs moved on from where they were, not from zero.
            #{promised := {Round, _}} = peace:overview(NewLeader),
            ?assert(Round >= 2)
        end)}.

%% The three together, through the public API and the dets backend.
sessions_snapshots_and_leases(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    Dir = filename:join([
        filename:basedir(user_cache, "peace_tests"),
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    Opts = (fast())#{
        storage => {peace_storage_dets, #{dir => Dir}},
        snapshot_interval => 3,
        read_lease_ms => 100
    },
    Config = fun(Id) -> Opts#{id => Id, members => Ids, machine => ?TEST_MACHINE} end,
    {setup, fun() -> ok end, fun(_) -> file:del_dir_r(Dir) end,
        ?_test(begin
            {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, Opts),
            Leader = await_leader(Ids),
            Put = fun(N) -> peace:propose(Ids, {put, N, N}, #{session => {me, N}}) end,
            [{ok, ok, Leader} = Put(N) || N <- lists:seq(1, 7)],
            %% A retry of the last value changes nothing and is answered.
            {ok, ok, Leader} = Put(7),
            %% Nor does a late copy of an earlier one, which is refused.
            {error, {session_superseded, 7}} = Put(2),
            #{snapshot_index := Snapshot, sessions := 1} = peace:overview(Leader),
            ?assert(Snapshot >= 6),
            %% A read under a lease takes no index.
            %% On a machine too busy to keep the heartbeat the lease lapses
            %% and the read goes through the log, so look for one that
            %% did not.
            ok = await(fun() ->
                #{last_index := Before} = peace:overview(Leader),
                {ok, 7, Leader} = peace:consistent_query(Leader, fun(#{kv := KV}) -> map_size(KV) end),
                case peace:overview(Leader) of
                    #{last_index := Before} -> {ok, ok};
                    _ -> retry
                end
            end),
            %% Everybody restarts from a snapshot and the tail of the log.
            [ok = peace:stop_server(Id) || Id <- Ids],
            [ok = peace:start_server(Config(Id)) || Id <- Ids],
            NewLeader = await_leader(Ids),
            {ok, 7, NewLeader} = peace:consistent_query(Ids, fun(#{kv := KV}) -> map_size(KV) end),
            %% The session table came back too.
            {ok, ok, NewLeader} = Put(7),
            {ok, 7, NewLeader} = peace:propose(NewLeader, {get, 7})
        end)}.

%% One server out and one in, on real processes.
change_members(Ids0) ->
    [A, B, C, D | _] = Ids0,
    Old = [A, B, C],
    ?_test(begin
        {ok, Old, []} = peace:start_cluster(Old, ?TEST_MACHINE, ?FAST),
        Leader = await_leader(Old),
        {ok, ok, Leader} = peace:propose(Old, {put, a, 1}),
        %% The newcomer is told who the cluster is, and waits.
        ok = peace:start_server((fast())#{id => D, members => Old, machine => ?TEST_MACHINE}),
        [Gone | Stay] = [Leader | Old -- [Leader]],
        New = lists:sort([D | Stay]),
        {ok, ok, Leader} = peace:change_members(Old, New, majority),
        %% The leader removed itself, saw it through and stood down.
        NewLeader = await_leader(New),
        ?assert(lists:member(NewLeader, New)),
        {ok, New, NewLeader} = peace:members(NewLeader),
        ok = peace:stop_server(Gone),
        {ok, 1, NewLeader} = peace:propose(New, {get, a}),
        %% The newcomer has the history from before it arrived.
        ok = await(fun() ->
            case history(D) of
                [{_, {put, a, 1}}, {_, {get, a}}] -> {ok, ok};
                _ -> retry
            end
        end)
    end).

machine_effects(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        Self = self(),
        {ok, Ids, []} = peace:start_cluster(Ids, {module, peace_test_machine, #{notify => Self}}, ?FAST),
        Leader = await_leader(Ids),
        %% state_enter runs on every server as its role changes.
        ok = receive_all([{state_enter, follower}, {state_enter, candidate}, {state_enter, leader}]),
        {ok, ok, Leader} = peace:propose(Leader, {tell, Self, hello}),
        ?assertEqual({told, hello}, receive_told()),
        %% Applied on three servers, performed by one.
        ?assertEqual(none, receive_told())
    end).

unsafe_quorum_is_refused(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        ?assertMatch(
            {error, {invalid_quorum, {quorums_do_not_intersect, _}}},
            peace:start_cluster(Ids, ?TEST_MACHINE, #{quorum => {counting, 2, 1}})
        ),
        %% The server checks for itself, whoever starts it.
        process_flag(trap_exit, true),
        ?assertMatch(
            {error, {invalid_quorum, _}},
            peace_server:start_link(#{
                id => hd(Ids), members => Ids, machine => ?TEST_MACHINE, quorum => {counting, 1, 1}
            })
        )
    end).

%% ---------------------------------------------------------------------------

await_leader(Ids) ->
    await(fun() ->
        Leaders = [Id || Id <- Ids, is_leader(Id)],
        case Leaders of
            [Leader] ->
                %% Stable only once everybody running agrees.
                Views = [L || Id <- Ids, {ok, _, L} <- [peace:members(Id, 200)]],
                case lists:usort(Views) of
                    [Leader] -> {ok, Leader};
                    _ -> retry
                end;
            _ ->
                retry
        end
    end).

is_leader(Id) ->
    case peace:overview(Id) of
        #{role := leader} -> true;
        _ -> false
    end.

history(Id) ->
    case peace:local_query(Id, fun(#{history := H}) -> lists:reverse(H) end) of
        {ok, H, _} -> H;
        _ -> unavailable
    end.

await(Fun) ->
    await(Fun, 200).

await(_Fun, 0) ->
    error(await_timeout);
await(Fun, N) ->
    case Fun() of
        {ok, Value} ->
            Value;
        retry ->
            timer:sleep(25),
            await(Fun, N - 1)
    end.

receive_all([]) ->
    ok;
receive_all(Wanted) ->
    receive
        Msg ->
            receive_all(lists:delete(Msg, Wanted))
    after 2000 -> {missing, Wanted}
    end.

receive_told() ->
    receive
        {told, _} = Told -> Told
    after 300 -> none
    end.

fast() ->
    #{election_timeout_ms => 100}.
