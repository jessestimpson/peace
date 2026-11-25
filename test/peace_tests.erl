%% These tests run the whole library with real processes on one node.
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
        fun rolling_upgrade/1,
        fun sessions_snapshots_and_leases/1,
        fun session_process_keeps_order_across_leaders/1,
        fun session_process_and_overloaded_leader/1,
        fun session_process_eviction/1,
        fun snapshot_in_chunks/1,
        fun change_members/1,
        fun rejoin/1,
        fun grid_formation_and_replacement/1,
        fun concurrent_formation/1,
        fun machine_effects/1,
        fun unsafe_quorum_is_refused/1,
        fun storage_failure_stops_server/1,
        fun default_storage_is_durable/1
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(peace),
    %% Each test uses different server names. A slow shutdown in one test
    %% then cannot collide with the next test.
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
        %% A request can be sent to any member. The request follows the
        %% redirect to the leader.
        [Follower | _] = Ids -- [Leader],
        {ok, 1, Leader} = peace:propose(Follower, {get, a}),
        {ok, #{a := 1}, Leader} = peace:consistent_query(Follower, fun(#{kv := KV}) -> KV end),
        {ok, Ids, Leader} = peace:members(Leader),
        ok = peace:propose_async(Leader, {put, b, 2}),
        {ok, 2, Leader} = peace:propose(Leader, {get, b}),
        %% Every server, the leader included, converges on the same history.
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
        %% The value that was acknowledged is still present.
        {ok, 1, NewLeader} = peace:propose(Rest, {get, a}),
        %% Stopping one more server leaves no majority. No value is
        %% acknowledged.
        [Last] = Rest -- [NewLeader],
        ok = peace:stop_server(NewLeader),
        ?assertMatch(
            Result when element(1, Result) =/= ok,
            peace:propose(Last, {put, a, 2}, 500)
        )
    end).

%% The cluster has five members and the quorum system {counting, 4, 2}.
%% Values commit with three members stopped. A majority quorum system cannot
%% commit values with three of five members stopped. The cost is that an
%% election needs more members.
flexible_quorum_survives_what_majority_cannot(Ids) ->
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, (fast())#{quorum => {counting, 4, 2}}),
        Leader = await_leader(Ids),
        [F1, F2, F3, F4] = Ids -- [Leader],
        [ok = peace:stop_server(F) || F <- [F2, F3, F4]],
        {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
        {ok, 1, Leader} = peace:propose(F1, {get, a}),
        %% The leader is stopped as well. One member remains. An election
        %% needs four promises, so the remaining member cannot be elected.
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
    Config = fun(Id) -> Opts#{id => Id, machine => ?TEST_MACHINE} end,
    {setup, fun() -> empty_dir(Dir) end, fun(_) -> file:del_dir_r(Dir) end,
        ?_test(begin
            {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, Opts),
            Leader = await_leader(Ids),
            {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
            %% Every server in the cluster is stopped and then started again.
            [ok = peace:stop_server(Id) || Id <- Ids],
            [ok = peace:start_server(Config(Id)) || Id <- Ids],
            NewLeader = await_leader(Ids),
            {ok, 1, NewLeader} = peace:propose(NewLeader, {get, a}),
            %% After the restart, epochs continue from the epoch before the
            %% restart. Epochs do not start again from zero.
            #{promised := {Round, _}} = peace:overview(NewLeader),
            ?assert(Round >= 2)
        end)}.

%% A cluster of three servers is upgraded twice while it runs, one server
%% at a time. The servers start with the message version 1. The first
%% upgrade adds version 2. The second upgrade adds version 3 and removes
%% version 1. Versions 2 and 3 are test versions. See `peace_wire'.
rolling_upgrade(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    Dir = filename:join([
        filename:basedir(user_cache, "peace_tests"),
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    Opts = (fast())#{storage => {peace_storage_dets, #{dir => Dir}}},
    Config = fun(Id, Range) -> Opts#{id => Id, machine => ?TEST_MACHINE, test_msg_versions => Range} end,
    Upgrade = fun(Id, Range, N) ->
        ok = peace:stop_server(Id),
        %% The other two servers decide a value while the server is stopped.
        %% A request can be redirected to the server that was stopped, so
        %% the request is repeated.
        Put = fun(Servers, Key) ->
            await(fun() ->
                case peace:propose(Servers, {put, Key, N}, #{timeout => 1000}) of
                    {ok, ok, _} -> {ok, Key};
                    _ -> retry
                end
            end)
        end,
        Put(Ids -- [Id], {down, N}),
        ok = peace:start_server(Config(Id, Range)),
        Put(Ids, {up, N}),
        %% The server that was upgraded applies every value.
        await(fun() ->
            case peace:local_query(Id, fun(State) -> State end) of
                {ok, #{kv := #{{up, N} := N}}, _} -> {ok, Id};
                _ -> retry
            end
        end)
    end,
    %% The ranges that the leader holds for the other servers. A follower
    %% receives no message from another follower, so only the leader holds
    %% the present range of every other server.
    Held = fun() ->
        Leader = await_leader(Ids),
        #{message_versions := #{peers := Peers}} = peace:overview(Leader),
        [maps:get(Id, Peers, unknown) || Id <- Ids -- [Leader]]
    end,
    {setup, fun() -> empty_dir(Dir) end, fun(_) -> file:del_dir_r(Dir) end,
        ?_test(begin
            [ok = peace:start_server(Config(Id, {1, 1})) || Id <- Ids],
            {ok, Ids, []} = peace:form_cluster(Ids, majority),
            _ = await_leader(Ids),
            {ok, ok, _} = peace:propose(Ids, {put, a, 1}),
            [Upgrade(Id, {1, 2}, N) || {N, Id} <- lists:zip([1, 2, 3], Ids)],
            ?assertEqual([{1, 2}, {1, 2}], Held()),
            [Upgrade(Id, {2, 3}, N) || {N, Id} <- lists:zip([4, 5, 6], Ids)],
            ?assertEqual([{2, 3}, {2, 3}], Held()),
            %% One server is started again with the earlier version of
            %% peace. The other servers send to it in version 3 until it
            %% answers with its range.
            [First | _] = Ids,
            Upgrade(First, {1, 2}, 7),
            Leader = await_leader(Ids),
            #{message_versions := #{own := Own, peers := Peers}} = peace:overview(Leader),
            ?assertEqual({1, 2}, maps:get(First, Peers#{Leader => Own})),
            ?assertMatch({ok, 1, Leader}, peace:propose(Leader, {get, a})),
            ?assertMatch({ok, 7, Leader}, peace:propose(Leader, {get, {down, 7}}))
        end)}.

%% This test uses sessions, snapshots and leases together, through the
%% public API and the dets backend.
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
    Config = fun(Id) -> Opts#{id => Id, machine => ?TEST_MACHINE} end,
    {setup, fun() -> empty_dir(Dir) end, fun(_) -> file:del_dir_r(Dir) end,
        ?_test(begin
            {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, Opts),
            Leader = await_leader(Ids),
            Put = fun(N) -> peace:propose(Ids, {put, N, N}, #{session => {me, N}}) end,
            [{ok, ok, Leader} = Put(N) || N <- lists:seq(1, 7)],
            %% A retry of the last value changes no state and is answered.
            {ok, ok, Leader} = Put(7),
            %% A late copy of an earlier value also changes no state. The
            %% reply is the reply to the earlier value.
            {ok, ok, Leader} = Put(2),
            %% A value that is not the next value of the session is not
            %% applied.
            {error, {session_gap, 7}} = Put(9),
            #{snapshot_index := Snapshot, sessions := 1} = peace:overview(Leader),
            ?assert(Snapshot >= 6),
            %% A read under a lease uses no index.
            %% On a computer that is too busy to send heartbeats on time,
            %% the lease ends and the read goes through the log. The test
            %% therefore retries until one read uses no index.
            ok = await(fun() ->
                #{last_index := Before} = peace:overview(Leader),
                {ok, 7, Leader} = peace:consistent_query(Leader, fun(#{kv := KV}) -> map_size(KV) end),
                case peace:overview(Leader) of
                    #{last_index := Before} -> {ok, ok};
                    _ -> retry
                end
            end),
            %% Every server restarts from a snapshot and the log entries
            %% after the snapshot.
            [ok = peace:stop_server(Id) || Id <- Ids],
            [ok = peace:start_server(Config(Id)) || Id <- Ids],
            NewLeader = await_leader(Ids),
            {ok, 7, NewLeader} = peace:consistent_query(Ids, fun(#{kv := KV}) -> map_size(KV) end),
            %% The restart also recovered the session table.
            {ok, ok, NewLeader} = Put(7),
            {ok, 7, NewLeader} = peace:propose(NewLeader, {get, 7})
        end)}.

%% A session process has 8 values undecided at a time. The leader is
%% stopped while values are undecided. Every value is applied once, in the
%% order of submission.
session_process_keeps_order_across_leaders(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, ?FAST),
        Leader = await_leader(Ids),
        {ok, S} = peace:open_session(Ids, #{window => 8, retry_ms => 200}),
        First = [peace:cast(S, {put, k, N}) || N <- lists:seq(1, 40)],
        ok = peace:stop_server(Leader),
        Second = [peace:cast(S, {put, k, N}) || N <- lists:seq(41, 100)],
        ?assertEqual([{ok, ok}], lists:usort(session_results(First ++ Second))),
        {ok, 100} = peace:call(S, {get, k}),
        {ok, Puts, _} = peace:consistent_query(
            Ids -- [Leader], fun(#{history := H}) -> [N || {_I, {put, k, N}} <- lists:reverse(H)] end
        ),
        ?assertEqual(lists:seq(1, 100), Puts),
        ok = peace:close_session(S)
    end).

%% The leader holds at most 2 undecided values and refuses the others. The
%% session process submits the refused values again.
session_process_and_overloaded_leader(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, (fast())#{max_pending => 2}),
        _ = await_leader(Ids),
        {ok, S} = peace:open_session(Ids, #{window => 16}),
        Refs = [peace:cast(S, {put, k, N}) || N <- lists:seq(1, 60)],
        ?assertEqual([{ok, ok}], lists:usort(session_results(Refs))),
        {ok, Puts, _} = peace:consistent_query(
            Ids, fun(#{history := H}) -> [N || {_I, {put, k, N}} <- lists:reverse(H)] end
        ),
        ?assertEqual(lists:seq(1, 60), Puts),
        ok = peace:close_session(S)
    end).

%% The cluster remembers one session. A value of a second session evicts
%% the first session.
session_process_eviction(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, (fast())#{max_sessions => 1}),
        _ = await_leader(Ids),
        {ok, S1} = peace:open_session(Ids),
        {ok, S2} = peace:open_session(Ids),
        {ok, ok} = peace:call(S1, {put, a, 1}),
        {ok, ok} = peace:call(S2, {put, b, 1}),
        {error, session_evicted} = peace:call(S1, {put, a, 2}),
        {ok, ok} = peace:call(S1, {put, a, 3}),
        {ok, 3} = peace:call(S1, {get, a}),
        ok = peace:close_session(S1),
        ok = peace:close_session(S2)
    end).

session_results(Refs) ->
    [
        receive
            {peace_reply, Ref, Result} -> Result
        after 10000 -> error({no_reply, Ref})
        end
     || Ref <- Refs
    ].

%% A server that restarts without data has a new incarnation. It replaces
%% the member that it was and receives a snapshot. The snapshot is larger
%% than one chunk.
snapshot_in_chunks(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    Opts = (fast())#{snapshot_interval => 4, snapshot_chunk_bytes => 64},
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, Opts),
        Leader = await_leader(Ids),
        [Behind | _] = Ids -- [Leader],
        #{member := Before} = peace:overview(Behind),
        ok = peace:stop_server(Behind),
        [{ok, ok, Leader} = peace:propose(Leader, {put, N, binary:copy(<<N>>, 100)}) || N <- lists:seq(1, 20)],
        #{snapshot_index := Snapshot} = peace:overview(Leader),
        ?assert(Snapshot >= 16),
        ok = peace:start_server(Opts#{id => Behind, machine => ?TEST_MACHINE}),
        #{member := After, members := []} = peace:overview(Behind),
        ?assertNotEqual(Before, After),
        {ok, ok, Leader} = peace:replace_member(Ids, Behind),
        ?assertMatch({ok, Ids, Leader}, peace:members(Leader)),
        #{config := {final, {Members, majority}}} = peace:overview(Leader),
        ?assert(lists:member(After, Members)),
        ?assertNot(lists:member(Before, Members)),
        Expected = history(Leader),
        ?assert(erlang:external_size(Expected) > 20 * 64),
        ok = await(fun() ->
            case history(Behind) of
                Expected -> {ok, ok};
                _ -> retry
            end
        end)
    end).

%% A server that is started with `rejoin' and without stored state replaces
%% the member that it was, without a call by an operator.
rejoin(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, ?FAST),
        Leader = await_leader(Ids),
        {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
        [Lost | _] = Ids -- [Leader],
        #{member := Before} = peace:overview(Lost),
        ok = peace:stop_server(Lost),
        ok = peace:start_server((fast())#{id => Lost, machine => ?TEST_MACHINE, rejoin => Ids}),
        #{member := After} = peace:overview(Lost),
        ok = await(fun() ->
            case peace:overview(Leader) of
                #{config := {final, {Members, majority}}} ->
                    case {lists:member(After, Members), lists:member(Before, Members)} of
                        {true, false} -> {ok, ok};
                        _ -> retry
                    end;
                _ ->
                    retry
            end
        end),
        ok = await(fun() ->
            case history(Lost) of
                [{_, {put, a, 1}}] -> {ok, ok};
                _ -> retry
            end
        end),
        ?assertMatch({ok, Ids, Leader}, peace:members(Lost))
    end).

%% A grid quorum system is given with addresses. A server that replaces a
%% member takes the row of that member.
grid_formation_and_replacement(Ids0) ->
    Ids = [A, B, C, D] = lists:sublist(Ids0, 4),
    Grid = {grid, [[A, B], [C, D]]},
    ?_test(begin
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, (?FAST)#{quorum => Grid}),
        Leader = await_leader(Ids),
        {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
        [Lost | _] = Ids -- [Leader],
        ok = peace:stop_server(Lost),
        ok = peace:start_server((fast())#{id => Lost, machine => ?TEST_MACHINE}),
        #{member := After} = peace:overview(Lost),
        {ok, ok, Leader} = peace:replace_member(Ids, Lost),
        #{config := {final, {Members, {grid, Rows}}}} = peace:overview(Leader),
        ?assertEqual(lists:sort(Members), lists:sort(lists:append(Rows))),
        ?assertEqual([[A, B], [C, D]], [[{N, Node} || {N, Node, _} <- Row] || Row <- Rows]),
        ?assert(lists:member(After, Members)),
        %% The members can be changed with addresses after the replacement.
        {ok, ok, _} = peace:change_members(Ids, [A, B, C], majority),
        ?assertMatch({ok, [A, B, C], _}, peace:members(A))
    end).

%% Several callers form the same cluster at the same time, as the nodes of
%% the Jepsen test do. Every call stores the same configuration, because
%% the incarnations are fixed when the servers start.
concurrent_formation(Ids) ->
    ?_test(begin
        [ok = peace:start_server((fast())#{id => Id, machine => ?TEST_MACHINE}) || Id <- Ids],
        Self = self(),
        Callers = [spawn_link(fun() -> Self ! {formed, peace:form_cluster(Ids, {counting, 4, 2})} end) || _ <- Ids],
        Results = [
            receive
                {formed, Result} -> Result
            after 5000 -> timeout
            end
         || _ <- Callers
        ],
        ?assertEqual([{ok, Ids, []}], lists:usort(Results)),
        Leader = await_leader(Ids),
        {ok, ok, Leader} = peace:propose(Ids, {put, a, 1}),
        Configs = lists:usort([Config || Id <- Ids, #{config := Config} <- [peace:overview(Id)]]),
        ?assertMatch([{final, {_, {counting, 4, 2}}}], Configs)
    end).

%% This test removes one server and adds one server, with real processes.
change_members(Ids0) ->
    [A, B, C, D | _] = Ids0,
    Old = [A, B, C],
    ?_test(begin
        {ok, Old, []} = peace:start_cluster(Old, ?TEST_MACHINE, ?FAST),
        Leader = await_leader(Old),
        {ok, ok, Leader} = peace:propose(Old, {put, a, 1}),
        %% The new server is started without a configuration. The new
        %% server then waits.
        ok = peace:start_server((fast())#{id => D, machine => ?TEST_MACHINE}),
        [Gone | Stay] = [Leader | Old -- [Leader]],
        New = lists:sort([D | Stay]),
        {ok, ok, Leader} = peace:change_members(Old, New, majority),
        %% The change removed the leader. The leader completed the change
        %% and then stopped leading.
        NewLeader = await_leader(New),
        ?assert(lists:member(NewLeader, New)),
        {ok, New, NewLeader} = peace:members(NewLeader),
        ok = peace:stop_server(Gone),
        {ok, 1, NewLeader} = peace:propose(New, {get, a}),
        %% The new server has the history from before the new server joined.
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
        %% state_enter runs on every server when the role of the server
        %% changes.
        ok = receive_all([{state_enter, follower}, {state_enter, candidate}, {state_enter, leader}]),
        {ok, ok, Leader} = peace:propose(Leader, {tell, Self, hello}),
        ?assertEqual({told, hello}, receive_told()),
        %% Three servers apply the value. Only one server performs the
        %% effect.
        ?assertEqual(none, receive_told())
    end).

unsafe_quorum_is_refused(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        ?assertMatch(
            {error, {invalid_quorum, {quorums_do_not_intersect, _}}},
            peace:start_cluster(Ids, ?TEST_MACHINE, #{quorum => {counting, 2, 1}})
        ),
        %% A server also validates the quorum system, regardless of which
        %% caller forms the cluster.
        [ok = peace:start_server((fast())#{id => Id, machine => ?TEST_MACHINE}) || Id <- Ids],
        Members = [Member || Id <- Ids, #{member := Member} <- [peace:overview(Id)]],
        ?assertMatch(
            {error, {invalid_quorum, _}},
            gen_server:call(hd(Ids), {form, {Members, {counting, 1, 1}}})
        ),
        %% A server stores only a configuration that names it.
        ?assertMatch({error, {not_named, _}}, gen_server:call(hd(Ids), {form, {tl(Members), majority}})),
        {ok, Ids, []} = peace:form_cluster(Ids, majority),
        %% The formation can be repeated. Another configuration is refused.
        {ok, Ids, []} = peace:form_cluster(Ids, majority),
        ?assertMatch({error, {already_formed, _}}, peace:form_cluster(Ids, {counting, 2, 2}))
    end).

%% ---------------------------------------------------------------------------

%% A server whose storage write fails stops before it sends anything that
%% depends on the write. The server is not restarted.
storage_failure_stops_server(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        Opts = (?FAST)#{storage => {peace_failing_storage, #{}}},
        {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, Opts),
        Leader = await_leader(Ids),
        {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
        [Follower, Other] = Ids -- [Leader],
        %% The follower stops at its next write. The other two servers are
        %% a majority and decide the value.
        ok = peace_failing_storage:fail(Follower, write),
        {ok, ok, Leader} = peace:propose(Leader, {put, a, 2}),
        ok = await(fun() ->
            case whereis(element(1, Follower)) of
                undefined -> {ok, ok};
                _ -> retry
            end
        end),
        timer:sleep(300),
        ?assertEqual(undefined, whereis(element(1, Follower))),
        %% The leader stops when it writes the next value. The leader sends
        %% the proposal before the write, so the last server can receive
        %% the proposal. The leader stops before it handles the answer, so
        %% the value is not decided.
        #{commit_index := Commit} = peace:overview(Other),
        ok = peace_failing_storage:fail(Leader, write),
        ?assertMatch({error, {server_down, _}}, peace:propose(Leader, {put, a, 3}, 1000)),
        timer:sleep(300),
        ?assertEqual(undefined, whereis(element(1, Leader))),
        ?assertMatch(#{commit_index := Commit}, peace:overview(Other)),
        %% A server whose storage fails to open does not start.
        ok = peace_failing_storage:fail(Leader, open),
        ?assertMatch(
            {error, {storage_failed, injected}},
            peace:start_server(Opts#{id => Leader, machine => ?TEST_MACHINE})
        )
    end).

%% A cluster that names no storage backend uses the write-ahead log in the
%% `data_dir' of the application. A server that is stopped and started
%% recovers its state.
default_storage_is_durable(Ids0) ->
    Ids = lists:sublist(Ids0, 3),
    ?_test(begin
        Dir = filename:join(
            filename:basedir(user_cache, "peace_tests"),
            "default_" ++ integer_to_list(erlang:unique_integer([positive]))
        ),
        ok = empty_dir(Dir),
        ok = application:set_env(peace, data_dir, Dir),
        try
            Opts = #{election_timeout_ms => 100},
            {ok, Ids, []} = peace:start_cluster(Ids, ?TEST_MACHINE, Opts),
            Leader = await_leader(Ids),
            {ok, ok, Leader} = peace:propose(Leader, {put, a, 1}),
            ?assertEqual(3, length(filelib:wildcard(filename:join([Dir, "*", "*.wal"])))),
            [ok = peace:stop_server(Id) || Id <- Ids],
            [ok = peace:start_server(Opts#{id => Id, machine => ?TEST_MACHINE}) || Id <- Ids],
            NewLeader = await_leader(Ids),
            ?assertMatch({ok, 1, NewLeader}, peace:propose(NewLeader, {get, a}))
        after
            application:unset_env(peace, data_dir),
            file:del_dir_r(Dir)
        end
    end).

%% `erlang:unique_integer/1' starts from the same values in every Erlang
%% node, so a later run of the tests gets the name of a directory of an
%% earlier run. A run that ends without its cleanup leaves the directory
%% with its data. Each test therefore deletes the directory before it uses
%% the directory, and again after the test.
empty_dir(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

await_leader(Ids) ->
    await(fun() ->
        Leaders = [Id || Id <- Ids, is_leader(Id)],
        case Leaders of
            [Leader] ->
                %% The leader is stable only when every running server
                %% reports the same leader.
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

%% The tests use the backend that stores nothing, unless a test is about
%% storage.
fast() ->
    #{election_timeout_ms => 100, storage => {peace_storage_mem, #{}}}.
