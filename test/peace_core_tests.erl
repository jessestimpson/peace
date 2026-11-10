%% The protocol with no processes: cores in a map, messages in a queue the
%% test delivers, drops or holds as it likes.
-module(peace_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_MACHINE, {module, peace_test_machine, #{}}).

%% ---------------------------------------------------------------------------
%% Tests
%% ---------------------------------------------------------------------------

elect_and_commit_test() ->
    S0 = new([a, b, c], majority),
    S1 = run(ev(a, election_timeout, S0)),
    ?assertEqual(leader, role(a, S1)),
    ?assertEqual([follower, follower], [role(I, S1) || I <- [b, c]]),
    S2 = run(ev(a, {command, c1, {put, k, 1}}, S1)),
    ?assertEqual([{c1, {ok, ok, a}}], replies(S2)),
    %% Followers learn the commit index from the next heartbeat.
    ?assertEqual([1, 0, 0], [commit(I, S2) || I <- [a, b, c]]),
    S3 = run(ev(a, heartbeat_timeout, S2)),
    ?assertEqual([1, 1, 1], [commit(I, S3) || I <- [a, b, c]]),
    ?assertEqual(kv(a, S3), kv(b, S3)),
    ?assertEqual(#{k => 1}, kv(c, S3)).

not_leader_test() ->
    S0 = run(ev(a, election_timeout, new([a, b, c], majority))),
    S1 = ev(b, {command, c1, {put, k, 1}}, S0),
    ?assertEqual([{c1, {error, {not_leader, a}}}], replies(S1)).

%% A value accepted by one follower, never decided, has to survive the leader
%% that proposed it: the next leader's phase-1 quorum may include the follower
%% that holds it.
new_leader_recovers_accepted_value_test() ->
    S0 = run(ev(a, election_timeout, new([a, b, c], majority))),
    %% Only b hears the accept, and its answer is lost.
    S1 = run(ev(a, {command, c1, {put, k, 1}}, block([{a, c}, {b, a}], S0))),
    ?assertEqual([], replies(S1)),
    ?assertEqual(0, commit(a, S1)),
    %% a is cut off. b leads with c's promise and re-proposes what it holds.
    S2 = run(ev(b, election_timeout, block([{a, b}, {a, c}, {b, a}, {c, a}], S1))),
    ?assertEqual(leader, role(b, S2)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, decided(b, S2)),
    %% a comes back, is fenced by the higher ballot, and learns the outcome.
    S3 = run(ev(b, heartbeat_timeout, run(ev(b, heartbeat_timeout, block([], S2))))),
    ?assertEqual(follower, role(a, S3)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, decided(a, S3)),
    %% The original caller was told the outcome was unknown, not that it failed.
    ?assertEqual([{c1, {error, leadership_lost}}], replies(S3)).

%% A new leader fills a slot nobody reported with a no-op, so that later
%% slots can be applied.
gaps_are_filled_with_noops_test() ->
    S0 = run(ev(a, election_timeout, new([a, b, c], majority))),
    %% Slot 1 reaches nobody; slot 2 reaches b.
    S1 = run(ev(a, {command, c1, {put, k, 1}}, block([{a, b}, {a, c}], S0))),
    S2 = run(ev(a, {command, c2, {put, k, 2}}, block([{a, c}, {b, a}], S1))),
    S3 = run(ev(b, election_timeout, block([{a, b}, {a, c}, {b, a}, {c, a}], S2))),
    ?assertEqual(#{1 => noop, 2 => {usr, {put, k, 2}}}, decided(b, S3)),
    ?assertEqual(#{k => 2}, kv(b, S3)).

%% {counting, 3, 1}: every member to elect, one to commit.
flexible_quorum_commits_alone_test() ->
    S0 = new([a, b, c], {counting, 3, 1}),
    %% Two promises are not a phase-1 quorum here.
    S1 = run(ev(a, election_timeout, block([{a, c}], S0))),
    ?assertEqual(candidate, role(a, S1)),
    S2 = run(ev(a, election_timeout, block([], S1))),
    ?assertEqual(leader, role(a, S2)),
    %% Nobody else hears the command, and it is decided all the same.
    S3 = run(ev(a, {command, c1, {put, k, 1}}, block([{a, b}, {a, c}], S2))),
    ?assertEqual([{c1, {ok, ok, a}}], replies(S3)),
    %% Which is safe only because nobody can be elected without a.
    S4 = run(ev(b, election_timeout, block([{a, b}, {b, a}], S3))),
    ?assertEqual(candidate, role(b, S4)).

%% The counterexample of formal/FPaxosNoConflictStepDown.cfg, against the code.
%%
%% a leads ballot 1 and gets its proposal X to b alone. c, d and e move on
%% without them and decide Y in the same slot. a, still believing it leads,
%% catches the slot up. If it kept leading, its commit index would cover the
%% slot, and b, holding X from a's own ballot, would take that as "X was
%% chosen".
deposed_leader_steps_down_on_conflict_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, election_timeout, block([{a, d}, {a, e}], new(Ids, majority)))),
    ?assertEqual(leader, role(a, S0)),
    S1 = run(ev(a, {command, cx, {put, k, x}}, block([{a, c}, {a, d}, {a, e}, {b, a}], S0))),
    Island = [{X, Y} || X <- [a, b], Y <- [c, d, e]] ++ [{Y, X} || X <- [a, b], Y <- [c, d, e]],
    S2 = run(ev(c, election_timeout, block(Island, S1))),
    ?assertEqual(leader, role(c, S2)),
    S3 = run(ev(c, {command, cy, {put, k, y}}, S2)),
    ?assertEqual(#{1 => {usr, {put, k, y}}}, decided(c, S3)),
    ?assertEqual(leader, role(a, S3)),
    %% An answer to a catch-up a asked for before it led, arriving late.
    {decided, Y} = maps:get(1, maps:get(entries, stored(c, S3))),
    S4 = run(ev(a, {msg, c, {learned, [{1, Y}]}}, S3)),
    ?assertEqual(follower, role(a, S4)),
    ?assertEqual({error, leadership_lost}, proplists:get_value(cx, replies(S4))),
    S5 = run(ev(a, heartbeat_timeout, block([{b, a}], S4))),
    ?assertEqual(#{}, decided(b, S5)),
    ?assertEqual(#{1 => {usr, {put, k, y}}}, decided(a, S5)).

%% Everything a server has promised or accepted is in its storage by the time
%% it says so, and a restart from that storage rebuilds the machine.
restart_recovers_from_storage_test() ->
    S0 = run(ev(a, election_timeout, new([a, b, c], majority))),
    S1 = run(ev(a, {command, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, heartbeat_timeout, run(ev(a, {command, c2, {put, j, 2}}, S1)))),
    S3 = restart(b, S2),
    ?assertEqual(follower, role(b, S3)),
    ?assertEqual(2, commit(b, S3)),
    ?assertEqual(#{k => 1, j => 2}, kv(b, S3)),
    %% Its promise survived too: a ballot below it is refused.
    S4 = ev(b, {msg, c, {prepare, {0, c}, 1}}, S3),
    ?assertMatch([{b, c, {nack, {1, a}}}], queue:to_list(maps:get(net, S4))).

consistent_query_is_ordered_by_the_log_test() ->
    S0 = run(ev(a, election_timeout, new([a, b, c], majority))),
    S1 = run(ev(a, {command, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, S1)),
    ?assertEqual({ok, #{k => 1}, a}, proplists:get_value(q1, replies(S2))),
    %% It took a slot, and changed nothing.
    ?assertEqual(#{1 => {usr, {put, k, 1}}, 2 => noop}, decided(a, S2)).

%% An outbid candidate learns the ballot to beat from the refusal.
nack_teaches_the_next_ballot_test() ->
    S0 = run(ev(a, election_timeout, new([a, b, c], majority))),
    S1 = run(ev(a, election_timeout, run(ev(b, election_timeout, block([{a, b}, {a, c}, {b, a}, {c, a}], S0))))),
    ?assertEqual(leader, role(b, S1)),
    ?assertEqual({2, b}, promised(c, S1)),
    %% a, isolated, is still on ballot 1. Reconnected, its stale accept is
    %% refused and its next campaign goes straight to round 3.
    S2 = run(ev(a, heartbeat_timeout, block([{b, a}], S1))),
    ?assertEqual(follower, role(a, S2)),
    S3 = run(ev(a, election_timeout, block([], S2))),
    ?assertEqual(leader, role(a, S3)),
    ?assertEqual({3, a}, promised(a, S3)).

%% ---------------------------------------------------------------------------
%% A network in a map
%% ---------------------------------------------------------------------------

new(Ids, Quorum) ->
    Cores = maps:from_list([{Id, start(Id, Ids, Quorum, #{})} || Id <- Ids]),
    #{
        ids => Ids,
        quorum => Quorum,
        cores => Cores,
        store => maps:from_list([{Id, #{entries => #{}}} || Id <- Ids]),
        net => queue:new(),
        blocked => [],
        replies => []
    }.

start(Id, Ids, Quorum, Stored) ->
    {Core, _Effects} = peace_core:init(
        #{id => Id, members => Ids, machine => ?TEST_MACHINE, quorum => Quorum}, Stored
    ),
    Core.

restart(Id, S = #{ids := Ids, quorum := Quorum, cores := Cores, store := Store}) ->
    S#{cores := Cores#{Id := start(Id, Ids, Quorum, maps:get(Id, Store))}}.

%% Replaces the set of one-way links that lose everything sent on them.
block(Pairs, S) ->
    S#{blocked := Pairs}.

ev(Id, Event, S = #{cores := Cores}) ->
    {Core, Effects} = peace_core:handle(Event, maps:get(Id, Cores)),
    ok = persist_precedes_what_depends_on_it(Effects),
    lists:foldl(fun(E, Acc) -> effect(Id, E, Acc) end, S#{cores := Cores#{Id := Core}}, Effects).

effect(Id, {send, To, Msg}, S = #{net := Net, blocked := Blocked}) ->
    case lists:member({Id, To}, Blocked) of
        true -> S;
        false -> S#{net := queue:in({Id, To, Msg}, Net)}
    end;
effect(Id, {persist, Batch}, S = #{store := Store}) ->
    Stored0 = #{entries := Entries0} = maps:get(Id, Store),
    Stored1 =
        case Batch of
            #{promised := B} -> Stored0#{promised => B};
            _ -> Stored0
        end,
    Entries = maps:merge(Entries0, maps:from_list(maps:get(entries, Batch, []))),
    S#{store := Store#{Id := Stored1#{entries := Entries}}};
effect(_Id, {reply, From, Reply}, S = #{replies := Replies}) ->
    S#{replies := Replies ++ [{From, Reply}]};
effect(_Id, {timer, _, _}, S) ->
    S;
effect(_Id, {machine, _}, S) ->
    S.

%% Delivers until nothing is in flight.
run(S = #{net := Net}) ->
    case queue:out(Net) of
        {empty, _} -> S;
        {{value, {From, To, Msg}}, Net1} -> run(ev(To, {msg, From, Msg}, S#{net := Net1}))
    end.

%% The core lists a persist before the first send or reply of the same batch
%% of effects. peace_server does not rely on it, but it is cheap to hold.
persist_precedes_what_depends_on_it(Effects) ->
    Kinds = [element(1, E) || E <- Effects, lists:member(element(1, E), [persist, send, reply])],
    case lists:dropwhile(fun(K) -> K =:= persist end, Kinds) of
        Rest ->
            case lists:member(persist, lists:dropwhile(fun(K) -> K =/= send end, Rest)) of
                false -> ok;
                true -> {persist_after_send, Effects}
            end
    end.

core(Id, #{cores := Cores}) -> maps:get(Id, Cores).
role(Id, S) -> peace_core:role(core(Id, S)).
commit(Id, S) -> peace_core:commit_index(core(Id, S)).
promised(Id, S) -> peace_core:promised(core(Id, S)).
decided(Id, S) -> peace_core:decided(core(Id, S)).
kv(Id, S) -> maps:get(kv, peace_core:machine_state(core(Id, S))).
stored(Id, #{store := Store}) -> maps:get(Id, Store).
replies(#{replies := Replies}) -> Replies.
