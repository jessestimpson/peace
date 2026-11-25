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

%% A snapshot removes the entries that it covers. A write with `promised'
%% is performed before every other effect.
merge_snapshot_test() ->
    Batches = [#{snapshot => {2, snap}}, #{entries => [{2, {learned, y}}, {3, {?E, z}}]}],
    ?assertEqual(
        {#{snapshot => {2, snap}, entries => [{3, {?E, z}}]}, true},
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

%% `peace_core' decides an index only on acceptances that are stored. A
%% `learned' entry that replaces a proposal of the same group is therefore
%% written like any other `learned' entry.
merge_proposed_and_decided_test() ->
    Batches = [#{entries => [{1, {?E, x}}]}, #{entries => [{1, {learned, x}}]}],
    ?assertEqual(
        {#{entries => [{1, {learned, x}}], sync => false}, true},
        peace_server:merge_batches(Batches)
    ).

%% The storage process performs a write between two steps of a snapshot.
write_between_snapshot_steps_test() ->
    Id = {peace_server_tests_writer, node()},
    {ok, Writer, #{}} = peace_writer:start_link(Id, peace_step_storage, #{test => self()}),
    Snapshot = #{snapshot => {2, {state, #{}, cfg}}},
    Batch = #{entries => [{3, {learned, x}}]},
    ok = peace_writer:snapshot(Writer, Snapshot),
    receive
        {began, Snapshot} -> ok
    end,
    receive
        {step, Writer} -> ok
    end,
    ok = peace_writer:write(Writer, 1, Batch),
    Writer ! go,
    %% The write returns before the second step ends.
    receive
        {written, Writer, 1} -> ok
    end,
    receive
        {wrote, Batch} -> ok
    end,
    ?assertEqual(none, receive {snapshot_written, Writer} -> stored after 0 -> none end),
    [receive {step, Writer} -> Writer ! go end || _ <- [2, 3]],
    receive
        {snapshot_written, Writer} -> ok
    end,
    ok = peace_writer:stop(Writer).

%% A server holds more client requests than `max_mailbox'. The server keeps
%% the oldest requests and refuses the newest. The requests that the server
%% keeps are applied in the order in which they arrived.
mailbox_limit_test() ->
    {Id, Pid} = start_single(peace_server_tests_mailbox, #{max_mailbox => 5}),
    true = erlang:suspend_process(Pid),
    Refs = [request(Pid, {value, {put, k, N}}) || N <- lists:seq(1, 20)],
    true = erlang:resume_process(Pid),
    Replies = [reply(Ref) || Ref <- Refs],
    ?assertEqual([{ok, ok, Id} || _ <- lists:seq(1, 5)], lists:sublist(Replies, 5)),
    ?assertEqual([{error, overloaded}], lists:usort(lists:nthtail(5, Replies))),
    {ok, Puts, Id} = peace:consistent_query(Id, fun(#{history := H}) -> [N || {_I, {put, k, N}} <- lists:reverse(H)] end),
    ?assertEqual(lists:seq(1, 5), Puts),
    %% The server accepts values again.
    ?assertEqual({ok, ok, Id}, peace:propose(Id, {put, k, 21})),
    ok = gen_server:stop(Pid).

%% The values of a session that a server keeps are the first values of the
%% session. No value is answered `session_gap'.
mailbox_limit_keeps_a_prefix_of_a_session_test() ->
    {Id, Pid} = start_single(peace_server_tests_prefix, #{max_mailbox => 4}),
    true = erlang:suspend_process(Pid),
    Refs = [request(Pid, {value, {put, k, N}, {me, N}}) || N <- lists:seq(1, 10)],
    true = erlang:resume_process(Pid),
    Replies = [reply(Ref) || Ref <- Refs],
    ?assertEqual(
        [{ok, ok, Id} || _ <- lists:seq(1, 4)] ++ [{error, overloaded} || _ <- lists:seq(5, 10)],
        Replies
    ),
    ok = gen_server:stop(Pid).

%% A server that is not the leader refuses with the leader that it knows.
mailbox_limit_on_a_follower_test() ->
    Id = {peace_server_tests_follower, node()},
    {ok, Pid} = peace_server:start_link(#{
        id => Id,
        machine => {module, peace_test_machine, #{}},
        storage => {peace_storage_mem, #{}},
        max_mailbox => 2
    }),
    true = erlang:suspend_process(Pid),
    Refs = [request(Pid, {value, {put, k, N}}) || N <- lists:seq(1, 6)],
    true = erlang:resume_process(Pid),
    Replies = [reply(Ref) || Ref <- Refs],
    ?assertEqual([{error, {not_leader, undefined}}], lists:usort(Replies)),
    unlink(Pid),
    ok = gen_server:stop(Pid).

%% A server handles a message only if the message names its incarnation.
message_for_another_incarnation_test() ->
    {Id = {Name, Node}, Pid} = start_single(peace_server_tests_incarnation, #{}),
    #{member := Me, promised := Promised} = peace:overview(Id),
    Peer = {peace_server_tests_peer, Node, <<"peer">>},
    Propose = {propose, {99, Peer}, [], 0, 0},
    #{message := Version, message_min := Min} = peace:versions(),
    Range = {Min, Version},
    Pid ! {peace_msg, Version, Range, Peer, {Name, Node, <<"another incarnation">>}, Propose},
    Pid ! {peace_msg, Version, Range, Peer, any, Propose},
    ?assertMatch(#{promised := Promised, role := leader}, peace:overview(Id)),
    %% A message of a version outside the range of the server, and a message
    %% without a version, are dropped.
    Pid ! {peace_msg, Version + 1, Range, Peer, Me, Propose},
    Pid ! {peace_chunk, Version + 1, Range, Peer, Me, {offer, 1}},
    Pid ! {peace_msg, Version, Peer, Me, Propose},
    Pid ! {peace_msg, Peer, Me, Propose},
    ?assertMatch(#{promised := Promised, role := leader}, peace:overview(Id)),
    Pid ! {peace_msg, Version, Range, Peer, Me, Propose},
    ?assertMatch(#{promised := {99, Peer}}, peace:overview(Id)),
    ok = gen_server:stop(Pid).

%% A server sends a message in the latest version that the server and the
%% receiver both handle. The server of this test handles the versions 2
%% and 3. The test process is the peer.
message_versions_test() ->
    PeerName = peace_server_tests_wire_peer,
    {Id = {_Name, Node}, Pid} = start_single(peace_server_tests_wire, #{test_msg_versions => {2, 3}}),
    true = register(PeerName, self()),
    #{member := Me, promised := Promised} = peace:overview(Id),
    Peer = {PeerName, Node, <<"peer">>},
    Propose = fun(Round) -> {propose, {Round, Peer}, [], 0, 0} end,
    Body = fun(Version, Round) -> {peace_test_version, Version, Propose(Round)} end,
    %% Version 1 is outside the range. The server drops the message and
    %% answers with its range.
    Pid ! {peace_msg, 1, {1, 1}, Peer, Me, Propose(99)},
    receive
        {peace_versions, {2, 3}, Me} -> ok
    after 1000 -> error(no_answer)
    end,
    ?assertMatch(
        #{promised := Promised, message_versions := #{own := {2, 3}, peers := #{{PeerName, Node} := {1, 1}}}},
        peace:overview(Id)
    ),
    %% A body that is not a body of version 2 is dropped.
    Pid ! {peace_msg, 2, {1, 2}, Peer, Me, Propose(99)},
    ?assertMatch(#{promised := Promised}, peace:overview(Id)),
    %% The peer handles the versions 1 and 2. The server answers in
    %% version 2.
    Pid ! {peace_msg, 2, {1, 2}, Peer, Me, Body(2, 99)},
    receive
        {peace_msg, 2, {2, 3}, Me, Peer, {peace_test_version, 2, _}} -> ok
    after 1000 -> error(no_answer_in_version_2)
    end,
    ?assertMatch(#{promised := {99, Peer}}, peace:overview(Id)),
    %% The peer handles the versions 2 and 3. The server answers in
    %% version 3, also to a message of version 2.
    Pid ! {peace_msg, 2, {2, 3}, Peer, Me, Body(2, 199)},
    receive
        {peace_msg, 3, {2, 3}, Me, Peer, {peace_test_version, 3, _}} -> ok
    after 1000 -> error(no_answer_in_version_3)
    end,
    %% `peace_versions' changes the range that the server holds for the
    %% peer.
    Pid ! {peace_versions, {2, 2}, Peer},
    ?assertMatch(#{message_versions := #{peers := #{{PeerName, Node} := {2, 2}}}}, peace:overview(Id)),
    true = unregister(PeerName),
    ok = gen_server:stop(Pid).

%% A server keeps its incarnation while it keeps its stored state. A server
%% does not start on stored state that it cannot be the owner of.
stored_identity_test() ->
    Dir = filename:join(filename:basedir(user_cache, "peace_tests"), "identity_" ++ integer_to_list(erlang:unique_integer([positive]))),
    %% A later run of the tests gets the same name, because
    %% `erlang:unique_integer/1' starts from the same values in every
    %% Erlang node. A directory of an earlier run is deleted.
    _ = file:del_dir_r(Dir),
    Storage = {peace_storage_dets, #{dir => Dir}},
    Config = fun(Name) -> #{id => {Name, node()}, machine => {module, peace_test_machine, #{}}, storage => Storage} end,
    Write = fun(Name, Batch) ->
        {ok, Tab, _} = peace_storage_dets:open({Name, node()}, #{dir => Dir}),
        {ok, Tab} = peace_storage_dets:write(Batch, Tab),
        ok = peace_storage_dets:close(Tab)
    end,
    try
        Kept = peace_server_tests_kept,
        {ok, Pid1} = peace_server:start(Config(Kept)),
        #{member := Member = {Kept, _, Incarnation}} = peace:overview({Kept, node()}),
        ?assertEqual(16, byte_size(Incarnation)),
        ok = gen_server:stop(Pid1),
        {ok, Pid2} = peace_server:start(Config(Kept)),
        ?assertMatch(#{member := Member}, peace:overview({Kept, node()})),
        ok = gen_server:stop(Pid2),
        %% The format of the stored data is stored with the identity.
        #{stored := Format} = peace:versions(),
        {ok, Tab0, #{meta := #{format := Format}}} = peace_storage_dets:open({Kept, node()}, #{dir => Dir}),
        ok = peace_storage_dets:close(Tab0),
        %% Data in a later format. The server does not start.
        ok = Write(peace_server_tests_later, #{meta => #{node => node(), incarnation => <<2>>, format => Format + 1}}),
        ?assertEqual(
            {error, {stored_format, Format + 1, Format}},
            peace_server:start(Config(peace_server_tests_later))
        ),
        %% Data without a format has format 1. The server starts.
        ok = Write(peace_server_tests_earlier, #{meta => #{node => node(), incarnation => <<3>>}}),
        {ok, Pid3} = peace_server:start(Config(peace_server_tests_earlier)),
        ?assertMatch(#{member := {_, _, <<3>>}}, peace:overview({peace_server_tests_earlier, node()})),
        ok = gen_server:stop(Pid3),
        %% The stored state of a server on another node.
        ok = Write(peace_server_tests_moved, #{meta => #{node => 'other@host', incarnation => <<1>>}}),
        ?assertEqual(
            {error, {stored_state_of_another_node, 'other@host'}},
            peace_server:start(Config(peace_server_tests_moved))
        ),
        %% A promise that was stored without an incarnation.
        ok = Write(peace_server_tests_old, #{promised => {1, x}}),
        ?assertEqual({error, stored_state_without_incarnation}, peace_server:start(Config(peace_server_tests_old)))
    after
        file:del_dir_r(Dir)
    end.

%% A storage backend supplies the incarnation of a server that recovers no
%% stored state.
incarnation_of_the_backend_test() ->
    Id = {Name, Node} = {peace_server_tests_supplied, node()},
    {ok, Pid} = peace_server:start(#{
        id => Id,
        machine => {module, peace_test_machine, #{}},
        storage => {peace_incarnation_storage, #{incarnation => {table, 7}}}
    }),
    ?assertMatch(#{member := {Name, Node, {table, 7}}}, peace:overview(Id)),
    ok = gen_server:stop(Pid).

%% `peace:form_cluster/3' forms a cluster with a machine state.
form_cluster_with_machine_state_test() ->
    Ids = [{Name, node()} || Name <- [peace_server_tests_f1, peace_server_tests_f2, peace_server_tests_f3]],
    Pids = [
        begin
            {ok, Pid} = peace_server:start(#{
                id => Id,
                machine => {module, peace_test_machine, #{}},
                storage => {peace_storage_mem, #{}},
                election_timeout_ms => 50
            }),
            Pid
        end
     || Id <- Ids
    ],
    MState = #{kv => #{k => 0}, history => [], notify => undefined},
    try
        ?assertEqual({ok, Ids, []}, peace:form_cluster(Ids, majority, #{machine_state => MState})),
        ?assertMatch({ok, ok, _}, until_leader(fun() -> peace:propose(Ids, {put, j, 1}) end, 100)),
        ?assertMatch({ok, #{k := 0, j := 1}, _}, peace:consistent_query(Ids, fun(#{kv := KV}) -> KV end)),
        %% The same formation is accepted again. Another state is refused.
        ?assertEqual({ok, Ids, []}, peace:form_cluster(Ids, majority, #{machine_state => MState})),
        ?assertMatch({error, _}, peace:form_cluster(Ids, majority, #{machine_state => MState#{kv := #{}}}))
    after
        [gen_server:stop(Pid) || Pid <- Pids]
    end.

%% `peace:form_cluster/3' with `members' forms a part of a cluster whose
%% incarnations the caller knows. The servers that are started later take
%% part without being formed.
form_cluster_with_members_test() ->
    Names = [peace_server_tests_m1, peace_server_tests_m2, peace_server_tests_m3],
    Ids = [First | Rest] = [{Name, node()} || Name <- Names],
    Members = [{Name, node(), {inc, Name}} || Name <- Names],
    Start = fun({Name, _} = Id) ->
        {ok, Pid} = peace_server:start(#{
            id => Id,
            machine => {module, peace_test_machine, #{}},
            storage => {peace_incarnation_storage, #{incarnation => {inc, Name}}},
            election_timeout_ms => 50
        }),
        Pid
    end,
    MState = #{kv => #{k => 0}, history => [], notify => undefined},
    Pid1 = Start(First),
    try
        Opts = #{members => Members, machine_state => MState},
        ?assertEqual({ok, [First], []}, peace:form_cluster([First], majority, Opts)),
        %% One member of three decides nothing.
        ?assertMatch({error, _}, peace:propose(First, {put, j, 1}, 300)),
        Pids = [Start(Id) || Id <- Rest],
        try
            ?assertMatch({ok, ok, _}, until_leader(fun() -> peace:propose(Ids, {put, j, 2}) end, 100)),
            %% A server that was not formed receives the machine state.
            Query = fun(Id) -> peace:local_query(Id, fun(#{kv := KV}) -> KV end) end,
            ?assertEqual(ok, until(fun() -> [maps:get(k, KV, none) || Id <- Ids, {ok, KV, _} <- [Query(Id)]] =:= [0, 0, 0] end, 100)),
            %% A configuration that does not name the server is refused.
            Other = [{peace_server_tests_m1, node(), other} | tl(Members)],
            ?assertMatch({error, _}, peace:form_cluster([First], majority, #{members => Other}))
        after
            [gen_server:stop(Pid) || Pid <- Pids]
        end
    after
        gen_server:stop(Pid1)
    end.

until(_Fun, 0) ->
    timeout;
until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            until(Fun, N - 1)
    end.

%% `peace:activate/1' makes a passive server an ordinary member.
activate_test() ->
    {Id, Pid} = start_single_unformed(peace_server_tests_passive, #{passive => true}),
    ?assertMatch(#{passive := true}, peace:overview(Id)),
    ?assertMatch({error, {cluster_not_formed, [{Id, {error, passive}}]}}, peace:form_cluster([Id], majority)),
    ?assertEqual(ok, peace:activate(Id)),
    ?assertMatch(#{passive := false}, peace:overview(Id)),
    ?assertEqual({ok, [Id], []}, peace:form_cluster([Id], majority)),
    ?assertEqual(ok, peace:activate(Id)),
    ok = gen_server:stop(Pid).

%% Calls `Fun' until a leader answers, at most `N' times.
until_leader(Fun, N) ->
    case Fun() of
        {error, no_leader} when N > 0 ->
            timer:sleep(20),
            until_leader(Fun, N - 1);
        Other ->
            Other
    end.

%% A server with a gate decides nothing while the gate is closed.
gate_test() ->
    Key = {?MODULE, gate},
    persistent_term:put(Key, false),
    {Id, Pid} = start_single_unformed(peace_server_tests_gate, #{
        gate => {persistent_term, get, [Key]},
        election_timeout_ms => 50
    }),
    try
        ?assertEqual({ok, [Id], []}, peace:form_cluster([Id], majority)),
        ?assertMatch({error, _}, peace:propose(Id, {put, k, 1}, 300)),
        ?assertMatch(#{gated := true, role := follower}, peace:overview(Id)),
        persistent_term:put(Key, true),
        ?assertMatch({ok, ok, _}, until_leader(fun() -> peace:propose(Id, {put, k, 2}) end, 100)),
        ?assertMatch(#{gated := false, role := leader}, peace:overview(Id)),
        %% The gate closes. The leader steps down at its next event.
        persistent_term:put(Key, false),
        ?assertEqual(ok, until(fun() -> maps:get(role, peace:overview(Id)) =:= follower end, 100)),
        ?assertMatch({error, _}, peace:propose(Id, {put, k, 3}, 300)),
        %% An exception of the function closes the gate.
        persistent_term:erase(Key),
        ?assertMatch({error, _}, peace:propose(Id, {put, k, 4}, 300))
    after
        persistent_term:erase(Key),
        gen_server:stop(Pid)
    end.

start_single_unformed(Name, Opts) ->
    Id = {Name, node()},
    {ok, Pid} = peace_server:start(Opts#{
        id => Id,
        machine => {module, peace_test_machine, #{}},
        storage => {peace_storage_mem, #{}}
    }),
    {Id, Pid}.

start_single(Name, Opts) ->
    Id = {Name, node()},
    {ok, Pid} = peace_server:start_link(Opts#{
        id => Id,
        machine => {module, peace_test_machine, #{}},
        storage => {peace_storage_mem, #{}},
        election_timeout_ms => 50
    }),
    {ok, [Id], []} = peace:form_cluster([Id], majority),
    ok = await_leader(Id, 100),
    {Id, Pid}.

await_leader(Id, 0) ->
    error({no_leader, Id});
await_leader(Id, N) ->
    case peace:overview(Id) of
        #{role := leader} ->
            ok;
        _ ->
            timer:sleep(20),
            await_leader(Id, N - 1)
    end.

%% Sends a call in the message format of `gen_server'. The test process
%% sends every request itself, so the requests arrive in order.
request(Pid, Request) ->
    Ref = make_ref(),
    Pid ! {'$gen_call', {self(), Ref}, Request},
    Ref.

reply(Ref) ->
    receive
        {Ref, Reply} -> Reply
    after 5000 -> error(no_reply)
    end.
