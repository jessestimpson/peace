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
    S1 = run(ev(a, force_election, S0)),
    ?assertEqual(leader, role(a, S1)),
    ?assertEqual([follower, follower], [role(I, S1) || I <- [b, c]]),
    S2 = run(ev(a, {value, c1, {put, k, 1}}, S1)),
    ?assertEqual([{c1, {ok, ok, a}}], replies(S2)),
    %% Followers learn the commit index from the next heartbeat.
    ?assertEqual([1, 0, 0], [commit(I, S2) || I <- [a, b, c]]),
    S3 = run(ev(a, heartbeat_timeout, S2)),
    ?assertEqual([1, 1, 1], [commit(I, S3) || I <- [a, b, c]]),
    ?assertEqual(kv(a, S3), kv(b, S3)),
    ?assertEqual(#{k => 1}, kv(c, S3)).

not_leader_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = ev(b, {value, c1, {put, k, 1}}, S0),
    ?assertEqual([{c1, {error, {not_leader, a}}}], replies(S1)).

%% A value accepted by one follower, never decided, has to survive the leader
%% that proposed it: the next leader's phase-one quorum may include the follower
%% that holds it.
new_leader_recovers_accepted_value_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    %% Only b hears the accept, and its answer is lost.
    S1 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, c}, {b, a}], S0))),
    ?assertEqual([], replies(S1)),
    ?assertEqual(0, commit(a, S1)),
    %% a is cut off. b leads with c's promise and re-proposes what it holds.
    S2 = run(ev(b, force_election, block([{a, b}, {a, c}, {b, a}, {c, a}], S1))),
    ?assertEqual(leader, role(b, S2)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, learned(b, S2)),
    %% a comes back, is fenced by the higher epoch, and learns the outcome.
    S3 = run(ev(b, heartbeat_timeout, run(ev(b, heartbeat_timeout, block([], S2))))),
    ?assertEqual(follower, role(a, S3)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, learned(a, S3)),
    %% The original caller was told the outcome was unknown, not that it failed.
    ?assertEqual([{c1, {error, leadership_lost}}], replies(S3)).

%% A new leader fills an index nobody reported with a no-op, so that later
%% indexes can be applied.
gaps_are_filled_with_noops_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    %% Index 1 reaches nobody; index 2 reaches b.
    S1 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, b}, {a, c}], S0))),
    S2 = run(ev(a, {value, c2, {put, k, 2}}, block([{a, c}, {b, a}], S1))),
    S3 = run(ev(b, force_election, block([{a, b}, {a, c}, {b, a}, {c, a}], S2))),
    ?assertEqual(#{1 => noop, 2 => {usr, {put, k, 2}}}, learned(b, S3)),
    ?assertEqual(#{k => 2}, kv(b, S3)).

%% {counting, 3, 1}: every member to elect, one to commit.
flexible_quorum_commits_alone_test() ->
    S0 = new([a, b, c], {counting, 3, 1}),
    %% Two promises are not a phase-one quorum here.
    S1 = run(ev(a, force_election, block([{a, c}], S0))),
    ?assertEqual(candidate, role(a, S1)),
    S2 = run(ev(a, force_election, block([], S1))),
    ?assertEqual(leader, role(a, S2)),
    %% Nobody else hears the value, and it is decided all the same.
    S3 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, b}, {a, c}], S2))),
    ?assertEqual([{c1, {ok, ok, a}}], replies(S3)),
    %% Which is safe only because nobody can be elected without a.
    S4 = run(ev(b, force_election, block([{a, b}, {b, a}], S3))),
    ?assertEqual(candidate, role(b, S4)).

%% The counterexample of formal/FPaxosNoConflictStepDown.cfg, against the code.
%%
%% a leads epoch 1 and gets its proposal X to b alone. c, d and e move on
%% without them and decide Y in the same index. a, still believing it leads,
%% catches the index up. If it kept leading, its commit index would cover the
%% index, and b, holding X from a's own epoch, would take that as "X was
%% decided".
deposed_leader_steps_down_on_conflict_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, block([{a, d}, {a, e}], new(Ids, majority)))),
    ?assertEqual(leader, role(a, S0)),
    S1 = run(ev(a, {value, cx, {put, k, x}}, block([{a, c}, {a, d}, {a, e}, {b, a}], S0))),
    Island = [{X, Y} || X <- [a, b], Y <- [c, d, e]] ++ [{Y, X} || X <- [a, b], Y <- [c, d, e]],
    S2 = run(ev(c, force_election, block(Island, S1))),
    ?assertEqual(leader, role(c, S2)),
    S3 = run(ev(c, {value, cy, {put, k, y}}, S2)),
    ?assertEqual(#{1 => {usr, {put, k, y}}}, learned(c, S3)),
    ?assertEqual(leader, role(a, S3)),
    %% An answer to a catch-up a asked for before it led, arriving late.
    {learned, Y} = maps:get(1, maps:get(entries, stored(c, S3))),
    S4 = run(ev(a, {msg, c, {learned, [{1, Y}]}}, S3)),
    ?assertEqual(follower, role(a, S4)),
    ?assertEqual({error, leadership_lost}, proplists:get_value(cx, replies(S4))),
    S5 = run(ev(a, heartbeat_timeout, block([{b, a}], S4))),
    ?assertEqual(#{}, learned(b, S5)),
    ?assertEqual(#{1 => {usr, {put, k, y}}}, learned(a, S5)).

%% The same hazard with the order reversed, found by the simulation's churn
%% workload. a learns an index it has not proposed in yet. Were it to go on
%% leading it would put its next value there, on top of the decided entry,
%% and b would take a's commit index to cover that value.
deposed_leader_steps_down_on_unproposed_index_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, block([{a, d}, {a, e}], new(Ids, majority)))),
    Island = [{X, Y} || X <- [a, b], Y <- [c, d, e]] ++ [{Y, X} || X <- [a, b], Y <- [c, d, e]],
    S1 = run(ev(c, force_election, block(Island, S0))),
    S2 = run(ev(c, {value, cy, {put, k, y}}, S1)),
    ?assertEqual(leader, role(a, S2)),
    {learned, Y} = maps:get(1, maps:get(entries, stored(c, S2))),
    S3 = run(ev(a, {msg, c, {learned, [{1, Y}]}}, S2)),
    ?assertEqual(follower, role(a, S3)),
    S4 = run(ev(a, {value, cx, {put, k, x}}, S3)),
    ?assertEqual({error, {not_leader, undefined}}, proplists:get_value(cx, replies(S4))),
    ?assertEqual(#{1 => {usr, {put, k, y}}}, learned(a, S4)),
    ?assertEqual(#{}, learned(b, S4)).

%% Everything a server has promised or accepted is in its storage by the time
%% it says so, and a restart from that storage rebuilds the machine.
restart_recovers_from_storage_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, heartbeat_timeout, run(ev(a, {value, c2, {put, j, 2}}, S1)))),
    S3 = restart(b, S2),
    ?assertEqual(follower, role(b, S3)),
    ?assertEqual(2, commit(b, S3)),
    ?assertEqual(#{k => 1, j => 2}, kv(b, S3)),
    %% Its promise survived too: an epoch below it is refused.
    S4 = ev(b, {msg, c, {prepare, {0, c}, 1}}, S3),
    ?assertMatch([{b, c, {nack, {1, a}}}], queue:to_list(maps:get(net, S4))).

consistent_query_is_ordered_by_the_log_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, S1)),
    ?assertEqual({ok, #{k => 1}, a}, proplists:get_value(q1, replies(S2))),
    %% It took an index, and changed nothing.
    ?assertEqual(#{1 => {usr, {put, k, 1}}, 2 => noop}, learned(a, S2)).

%% An outbid candidate learns the epoch to beat from the refusal.
nack_teaches_the_next_epoch_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, force_election, run(ev(b, force_election, block([{a, b}, {a, c}, {b, a}, {c, a}], S0))))),
    ?assertEqual(leader, role(b, S1)),
    ?assertEqual({2, b}, promised(c, S1)),
    %% a, isolated, is still on epoch 1. Reconnected, its stale accept is
    %% refused and its next campaign goes straight to round 3.
    S2 = run(ev(a, heartbeat_timeout, block([{b, a}], S1))),
    ?assertEqual(follower, role(a, S2)),
    S3 = run(ev(a, force_election, block([], S2))),
    ?assertEqual(leader, role(a, S3)),
    ?assertEqual({3, a}, promised(a, S3)).

%% A server that was cut off asks before it raises its epoch, and is told
%% no by everybody who still has a leader. It comes back as a follower.
prevote_does_not_disturb_a_leader_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    Cut = [{c, a}, {c, b}, {a, c}, {b, c}],
    S1 = run(ev(c, election_timeout, run(ev(c, election_timeout, block(Cut, S0))))),
    ?assertEqual({1, a}, promised(c, S1)),
    S2 = run(ev(c, election_timeout, block([], S1))),
    ?assertEqual([leader, follower, follower], [role(I, S2) || I <- [a, b, c]]),
    ?assertEqual([{1, a}, {1, a}, {1, a}], [promised(I, S2) || I <- [a, b, c]]),
    S3 = run(ev(a, heartbeat_timeout, S2)),
    ?assertEqual({ok, [a, b, c], a}, {ok, peace_core:members(core(c, S3)), peace_core:leader(core(c, S3))}).

%% When the leader really is gone, the first follower to notice is refused
%% by the one that has not noticed yet, and the second is not.
prevote_elects_once_the_leader_is_missed_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    S1 = run(ev(b, election_timeout, block(Gone, S0))),
    ?assertEqual(follower, role(b, S1)),
    ?assertEqual({1, a}, promised(b, S1)),
    S2 = run(ev(c, election_timeout, S1)),
    ?assertEqual(leader, role(c, S2)),
    ?assertEqual({2, c}, promised(b, S2)).

%% A leader that a phase-two quorum has stopped answering steps down, and
%% whoever was waiting on it is told the outcome is unknown.
leader_without_a_quorum_steps_down_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    %% Everybody answered the first heartbeat.
    S1 = run(ev(a, election_timeout, S0)),
    ?assertEqual(leader, role(a, S1)),
    %% One follower is enough for a majority of three.
    S2 = run(ev(a, election_timeout, run(ev(a, heartbeat_timeout, block([{a, c}], S1))))),
    ?assertEqual(leader, role(a, S2)),
    Alone = [{a, b}, {a, c}],
    S3 = run(ev(a, {value, c1, {put, k, 1}}, block(Alone, S2))),
    S4 = run(ev(a, election_timeout, run(ev(a, heartbeat_timeout, S3)))),
    ?assertEqual(follower, role(a, S4)),
    ?assertEqual([{c1, {error, leadership_lost}}], replies(S4)).

%% {counting, 3, 1}: the leader decides alone, so it never has cause to.
leader_that_commits_alone_never_steps_down_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], {counting, 3, 1}))),
    S1 = run(ev(a, election_timeout, run(ev(a, election_timeout, block([{a, b}, {a, c}], S0))))),
    ?assertEqual(leader, role(a, S1)).

%% A value decided twice under one session is applied once, and the second
%% copy is answered as the first was.
session_applies_once_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {value, c1, {put, k, 1}, {me, 1}}, S0)),
    S2 = run(ev(a, {value, c2, {put, k, 2}}, S1)),
    %% The retry: same session, and by now k is 2.
    S3 = run(ev(a, {value, c3, {put, k, 1}, {me, 1}}, S2)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c3, replies(S3))),
    ?assertEqual(#{k => 2}, kv(a, S3)),
    ?assertEqual(3, commit(a, S3)),
    %% The next value of the session is a new value.
    S4 = run(ev(a, {value, c4, {put, k, 4}, {me, 2}}, S3)),
    ?assertEqual(#{k => 4}, kv(a, S4)),
    %% And a copy of the old one, turning up late, is refused.
    S5 = run(ev(a, {value, c5, {put, k, 1}, {me, 1}}, S4)),
    ?assertEqual({error, {session_superseded, 2}}, proplists:get_value(c5, replies(S5))),
    ?assertEqual(#{k => 4}, kv(a, S5)),
    %% Followers reach the same state by the same route.
    S6 = run(ev(a, heartbeat_timeout, S5)),
    ?assertEqual([#{k => 4}, #{k => 4}], [kv(I, S6) || I <- [b, c]]).

%% Sessions are evicted oldest index first, on every server alike.
sessions_are_bounded_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority, #{max_sessions => 2}))),
    S1 = lists:foldl(
        fun(N, S) -> run(ev(a, {value, N, {put, N, N}, {N, 1}}, S)) end, S0, [1, 2, 3]
    ),
    ?assertMatch(#{sessions := 2}, peace_core:overview(core(a, S1))),
    %% Client 1 was evicted, so its retry is a new value.
    S2 = run(ev(a, {value, again, {put, 1, again}, {1, 1}}, S1)),
    ?assertEqual(again, maps:get(1, kv(a, S2))).

%% The log is dropped up to a snapshot, and a restart starts from it.
snapshot_truncates_and_recovers_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority, #{snapshot_interval => 2}))),
    S1 = lists:foldl(
        fun(N, S) -> run(ev(a, {value, N, {put, N, N}, {me, N}}, S)) end, S0, [1, 2, 3]
    ),
    ?assertEqual(2, peace_core:snapshot_index(core(a, S1))),
    ?assertEqual([3], maps:keys(peace_core:log(core(a, S1)))),
    ?assertMatch(#{snapshot := {2, _}, entries := #{3 := _}}, stored(a, S1)),
    ?assertEqual([3], maps:keys(maps:get(entries, stored(a, S1)))),
    S2 = restart(a, S1),
    ?assertEqual(3, commit(a, S2)),
    ?assertEqual(#{1 => 1, 2 => 2, 3 => 3}, kv(a, S2)),
    %% The session table came back with it.
    S3 = run(ev(a, force_election, S2)),
    S4 = run(ev(a, {value, retry, {put, 3, retried}, {me, 3}}, S3)),
    ?assertEqual(3, maps:get(3, kv(a, S4))).

%% A follower too far behind for the log is sent the state.
lagging_follower_is_sent_a_snapshot_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority, #{snapshot_interval => 2}))),
    S1 = lists:foldl(
        fun(N, S) -> run(ev(a, {value, N, {put, N, N}}, S)) end, block([{a, c}], S0), [1, 2, 3]
    ),
    ?assertEqual(0, commit(c, S1)),
    S2 = run(ev(a, heartbeat_timeout, run(ev(a, heartbeat_timeout, block([], S1))))),
    ?assertEqual(3, commit(c, S2)),
    ?assertEqual(kv(a, S2), kv(c, S2)),
    ?assertMatch(#{snapshot := {_, _}}, stored(c, S2)).

%% The counterexample of formal/FPaxosNoSnapshotGuard.cfg, against the code.
%%
%% c missed two values that a and b have since dropped from their logs. If
%% it campaigned on b's promise, which says nothing about indexes b no longer
%% holds, it would take them to be free, put its own values there and
%% count b's acknowledgement.
candidate_behind_a_snapshot_does_not_lead_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority, #{snapshot_interval => 2}))),
    S1 = lists:foldl(
        fun(N, S) -> run(ev(a, {value, N, {put, N, N}}, S)) end, block([{a, c}], S0), [1, 2]
    ),
    S2 = run(ev(a, heartbeat_timeout, run(ev(a, heartbeat_timeout, S1)))),
    ?assertEqual([2, 2, 0], [peace_core:snapshot_index(core(I, S2)) || I <- [a, b, c]]),
    NoA = [{a, b}, {a, c}, {b, a}, {c, a}],
    S3 = run(ev(c, force_election, block(NoA, S2))),
    ?assertEqual(follower, role(c, S3)),
    %% It asked b for what it was missing instead, and may lead now.
    ?assertEqual(2, commit(c, S3)),
    S4 = run(ev(c, force_election, S3)),
    ?assertEqual(leader, role(c, S4)),
    ?assertEqual(#{1 => 1, 2 => 2}, kv(c, S4)).

without_the_snapshot_guard_a_index_is_decided_twice_test() ->
    Extra = #{snapshot_interval => 2, unsafe_no_snapshot_guard => true},
    S0 = run(ev(a, force_election, new([a, b, c], majority, Extra))),
    S1 = lists:foldl(
        fun(N, S) -> run(ev(a, {value, N, {put, N, N}}, S)) end, block([{a, c}], S0), [1, 2]
    ),
    S2 = run(ev(a, heartbeat_timeout, run(ev(a, heartbeat_timeout, S1)))),
    ?assertEqual(2, peace_core:snapshot_index(core(b, S2))),
    NoA = [{a, b}, {a, c}, {b, a}, {c, a}],
    S3 = run(ev(c, force_election, block(NoA, S2))),
    ?assertEqual(leader, role(c, S3)),
    %% Index 1 looks free to c, and b acknowledges whatever is sent for it.
    S4 = run(ev(c, {value, cz, {put, 1, other}}, S3)),
    ?assertEqual({ok, ok, c}, proplists:get_value(cz, replies(S4))),
    ?assertEqual(#{1 => 1, 2 => 2}, kv(a, S4)),
    ?assertEqual(#{1 => other}, kv(c, S4)).

%% With a lease, a read is answered without an index, for as long as nobody
%% else can have been elected.
lease_read_takes_no_index_test() ->
    S0 = run(ev(a, force_election, at(100, new([a, b, c], majority, #{read_lease_ms => 100})))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, at(150, S1))),
    ?assertEqual({ok, #{k => 1}, a}, proplists:get_value(q1, replies(S2))),
    ?assertEqual(1, peace_core:last_index(core(a, S2))),
    %% Ninety milliseconds after the last answer the leader stops trusting
    %% it, ten before the followers stop honouring it.
    S3 = run(ev(a, {query, q2, fun(#{kv := KV}) -> KV end}, block([{a, b}, {a, c}], at(195, S2)))),
    ?assertEqual(undefined, proplists:get_value(q2, replies(S3))),
    ?assertEqual(2, peace_core:last_index(core(a, S3))).

%% While they honour it, followers promise nobody else and do not campaign.
lease_holders_do_not_promise_test() ->
    S0 = run(ev(a, force_election, at(100, new([a, b, c], majority, #{read_lease_ms => 100})))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    S1 = run(ev(b, force_election, block(Gone, at(150, S0)))),
    ?assertEqual([follower, {1, a}], [role(b, S1), promised(b, S1)]),
    S2 = run(ev(c, {msg, b, {prepare, {2, b}, 1}}, S1)),
    ?assertEqual({1, a}, promised(c, S2)),
    %% And afterwards they do.
    S3 = run(ev(b, force_election, at(200, S2))),
    ?assertEqual(leader, role(b, S3)).

%% A server that restarts has forgotten its lease, and honours a full one.
lease_survives_a_restart_test() ->
    S0 = run(ev(a, force_election, at(100, new([a, b, c], majority, #{read_lease_ms => 100})))),
    S1 = restart(c, restart(b, at(150, S0))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    S2 = run(ev(b, force_election, block(Gone, at(60, S1)))),
    ?assertEqual(follower, role(b, S2)).

%% {counting, 4, 2} over five: the leader and one follower leave three, who
%% cannot elect anybody. Fewer than a majority, fewer than any quorum, and
%% enough.
lease_needs_only_to_block_phase_one_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, at(100, new(Ids, {counting, 4, 2}, #{read_lease_ms => 100})))),
    OnlyB = [{a, c}, {a, d}, {a, e}],
    S1 = run(ev(a, heartbeat_timeout, block(OnlyB, at(300, S0)))),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, at(310, S1))),
    ?assertEqual({ok, #{}, a}, proplists:get_value(q1, replies(S2))),
    ?assertEqual(0, peace_core:last_index(core(a, S2))),
    %% Alone, it cannot know.
    S3 = run(ev(a, {query, q2, fun(#{kv := KV}) -> KV end}, block([{a, b} | OnlyB], at(400, S2)))),
    ?assertEqual(undefined, proplists:get_value(q2, replies(S3))).

%% Every member replaced, with nobody in common.
change_members_to_a_disjoint_set_test() ->
    S0 = run(ev(a, force_election, join([d, e, f], new([a, b, c], majority)))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, {reconfigure, r1, {[d, e, f], majority}}, S1)),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S2))),
    %% Having seen its own removal through, a no longer leads.
    ?assertEqual(follower, role(a, S2)),
    ?assertEqual({final, {[d, e, f], majority}}, peace_core:config(core(a, S2))),
    %% The new members carry on by themselves, with what was decided before.
    Old = [{X, Y} || X <- [a, b, c], Y <- [d, e, f]] ++ [{Y, X} || X <- [a, b, c], Y <- [d, e, f]],
    S3 = run(ev(d, force_election, block(Old, S2))),
    ?assertEqual(leader, role(d, S3)),
    S4 = run(ev(d, {value, c2, {put, j, 2}}, S3)),
    ?assertEqual({ok, ok, d}, proplists:get_value(c2, replies(S4))),
    ?assertEqual(#{k => 1, j => 2}, kv(d, S4)),
    ?assertEqual([d, e, f], members(e, run(ev(d, heartbeat_timeout, S4)))),
    %% And the old ones can no longer lead anything.
    S5 = run(ev(b, force_election, block([], S4))),
    ?assertEqual(candidate, role(b, S5)),
    ?assertEqual([leader, {2, d}, {2, d}], [role(d, S5), promised(e, S5), promised(f, S5)]).

%% While both are in force nothing is decided without a quorum of each, and
%% no second change is taken.
joint_configuration_needs_both_test() ->
    S0 = run(ev(a, force_election, join([d, e], new([a, b, c], majority)))),
    NoNew = [{a, d}, {a, e}],
    S1 = run(ev(a, {reconfigure, r1, {[a, d, e], majority}}, block(NoNew, S0))),
    ?assertEqual(undefined, proplists:get_value(r1, replies(S1))),
    ?assertEqual({joint, {[a, b, c], majority}, {[a, d, e], majority}}, peace_core:config(core(a, S1))),
    ?assertEqual([a, b, c, d, e], members(a, S1)),
    %% b and c acknowledge, and that is a quorum of the old only.
    S2 = run(ev(a, {value, c1, {put, k, 1}}, S1)),
    ?assertEqual(undefined, proplists:get_value(c1, replies(S2))),
    S3 = run(ev(a, {reconfigure, r2, {[a, b], majority}}, S2)),
    ?assertEqual({error, reconfiguration_in_progress}, proplists:get_value(r2, replies(S3))),
    %% d is enough of the new.
    S4 = run(ev(a, heartbeat_timeout, run(ev(a, heartbeat_timeout, block([{a, e}], S3))))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S4))),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S4))),
    ?assertEqual({final, {[a, d, e], majority}}, peace_core:config(core(a, S4))).

%% The change is in the log, so the next leader finishes it.
change_survives_its_leader_test() ->
    S0 = run(ev(a, force_election, join([d], new([a, b, c], majority)))),
    %% The joint entry reaches b and nobody else, and a is gone.
    S1 = run(ev(a, {reconfigure, r1, {[b, c, d], majority}}, block([{a, c}, {a, d}, {b, a}], S0))),
    Gone = [{a, X} || X <- [b, c, d]] ++ [{X, a} || X <- [b, c, d]],
    S2 = run(ev(b, force_election, block(Gone, S1))),
    ?assertEqual(leader, role(b, S2)),
    ?assertEqual({final, {[b, c, d], majority}}, peace_core:config(core(b, S2))),
    S3 = run(ev(b, heartbeat_timeout, S2)),
    ?assertEqual([[b, c, d], [b, c, d]], [members(I, S3) || I <- [c, d]]).

%% The counterexample of formal/ReconfigNoClosure.cfg, against the code. c
%% missed a change that left it one of three among strangers. b's promise is
%% a quorum of the configuration c knows, and tells c of one it does not:
%% c needs a quorum of that too, and asks the servers it names.
a_promise_raises_the_bar_test() ->
    S0 = run(ev(a, force_election, join([d, e], new([a, b, c], majority)))),
    S1 = run(ev(a, {reconfigure, r1, {[c, d, e], majority}}, block([{a, c}], S0))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    ?assertEqual([a, b, c], members(c, S1)),
    %% Only b answers.
    Only = [{c, a}, {c, d}, {c, e}],
    S2 = run(ev(c, force_election, block(Only, S1))),
    ?assertEqual(candidate, role(c, S2)),
    %% With d as well it has a majority of [c, d, e].
    S3 = run(ev(c, force_election, block([{c, a}, {c, e}], S2))),
    ?assertEqual(leader, role(c, S3)),
    ?assertEqual({final, {[c, d, e], majority}}, peace_core:config(core(c, S3))).

%% A server that was removed and has not heard cannot disturb those who have.
removed_server_cannot_depose_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {reconfigure, r1, {[a, b], majority}}, block([{a, c}], S0))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    S2 = run(ev(a, heartbeat_timeout, S1)),
    S3 = run(ev(c, force_election, block([], S2))),
    ?assertEqual([leader, {1, a}], [role(a, S3), promised(b, S3)]).

%% Only the quorum system changes: majority to two-to-commit over four.
change_quorum_system_only_test() ->
    Ids = [a, b, c, d],
    S0 = run(ev(a, force_election, new(Ids, majority))),
    S1 = run(ev(a, {reconfigure, r1, {Ids, {counting, 3, 2}}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    S2 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, c}, {a, d}], S1))),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S2))),
    S3 = run(ev(a, {reconfigure, r2, {Ids, {counting, 2, 2}}}, S2)),
    ?assertMatch({error, {invalid_quorum, _}}, proplists:get_value(r2, replies(S3))).

%% The counterexample of formal/ReconfigNoJoint.cfg, against the code:
%% straight to the new configuration, and the two decide separately.
without_a_joint_configuration_two_sides_decide_test() ->
    Extra = #{unsafe_no_joint => true},
    S0 = run(ev(a, force_election, join([d], new([a, b, c], majority, Extra)))),
    %% The change reaches d alone, which is the whole new configuration.
    S1 = run(ev(a, {reconfigure, r1, {[d], majority}}, block([{a, b}, {a, c}], S0))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    %% b and c never heard of it and are a majority of the old.
    Apart = [{X, Y} || X <- [b, c], Y <- [a, d]] ++ [{Y, X} || X <- [b, c], Y <- [a, d]],
    S2 = run(ev(b, force_election, block(Apart, S1))),
    S3 = run(ev(b, {value, c1, {put, k, 1}}, S2)),
    ?assertEqual({ok, ok, b}, proplists:get_value(c1, replies(S3))),
    ?assertMatch(#{1 := {cfg, _}}, learned(a, S3)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, learned(b, S3)).

%% Two to commit out of five: each value goes to one peer, and the other
%% three hear of it on the heartbeat and ask.
propose_to_quorum_sends_to_a_phase_two_quorum_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, new(Ids, {counting, 4, 2}, #{propose_to => quorum}))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S1))),
    ?assertEqual([b], sent_index(a, 1, S1)),
    ?assertEqual([1, 0, 0, 0, 0], [commit(I, S1) || I <- Ids]),
    %% One heartbeat tells them the commit index has moved; they ask, are
    %% told, and a second is not needed.
    S2 = run(ev(a, heartbeat_timeout, S1)),
    ?assertEqual([1, 1, 1, 1, 1], [commit(I, S2) || I <- Ids]),
    ?assertEqual([b], sent_index(a, 1, S2)),
    ?assertEqual(lists:duplicate(5, #{k => 1}), [kv(I, S2) || I <- Ids]).

%% A majority of five is the leader and two.
propose_to_quorum_majority_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, new(Ids, majority, #{propose_to => quorum}))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S1))),
    ?assertEqual([b, c], sent_index(a, 1, S1)).

%% A grid is not a count. From c the other row, a and b, is a quorum too,
%% and the first one a greedy choice would find; d alone is the smaller.
propose_to_quorum_grid_test() ->
    Grid = {grid, [[a, b], [c, d]]},
    S0 = run(ev(c, force_election, new([a, b, c, d], Grid, #{propose_to => quorum}))),
    S1 = run(ev(c, {value, c1, {put, k, 1}}, S0)),
    ?assertEqual({ok, ok, c}, proplists:get_value(c1, replies(S1))),
    ?assertEqual([d], sent_index(c, 1, S1)).

%% The peer it counted on is gone. The index waits one heartbeat, goes to
%% everybody on the next, and the leader then counts on somebody else.
propose_to_quorum_falls_back_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, new(Ids, {counting, 4, 2}, #{propose_to => quorum}))),
    S1 = run(ev(a, election_timeout, S0)),
    ?assertEqual([b], preferred(a, S1)),
    S2 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, b}], S1))),
    ?assertEqual(undefined, proplists:get_value(c1, replies(S2))),
    S3 = run(ev(a, heartbeat_timeout, S2)),
    ?assertEqual([b], sent_index(a, 1, S3)),
    ?assertEqual(undefined, proplists:get_value(c1, replies(S3))),
    S4 = run(ev(a, heartbeat_timeout, S3)),
    ?assertEqual([b, c, d, e], sent_index(a, 1, S4)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S4))),
    %% b has not answered since the timer last fired, and the others have.
    S5 = run(ev(a, election_timeout, S4)),
    ?assertEqual([c], preferred(a, S5)),
    S6 = run(ev(a, {value, c2, {put, k, 2}}, S5)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c2, replies(S6))),
    ?assertEqual([c], sent_index(a, 2, S6)).

%% During a change of membership, a quorum of each.
propose_to_quorum_follows_the_configuration_test() ->
    S0 = run(ev(a, force_election, join([d, e], new([a, b, c], majority, #{propose_to => quorum})))),
    S1 = run(ev(a, {reconfigure, r1, {[a, d, e], majority}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    %% The joint entry went to one of the old and one of the new.
    ?assertEqual([b, d], sent_index(a, 1, S1)),
    S2 = run(ev(a, {value, c1, {put, k, 1}}, S1)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S2))),
    ?assertEqual([d], sent_index(a, 3, S2)).

%% ---------------------------------------------------------------------------
%% A network in a map
%% ---------------------------------------------------------------------------

new(Ids, Quorum) ->
    new(Ids, Quorum, #{}).

new(Ids, Quorum, Extra) ->
    put(extra_config, Extra),
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
        maps:merge(
            #{id => Id, members => Ids, machine => ?TEST_MACHINE, quorum => Quorum},
            case get(extra_config) of
                undefined -> #{};
                Extra -> Extra
            end
        ),
        Stored
    ),
    Core.

%% Starts servers outside the cluster: each knows the members, and is not
%% one.
join(New, S = #{ids := Ids, quorum := Quorum, cores := Cores, store := Store}) ->
    S#{
        cores := maps:merge(Cores, maps:from_list([{Id, start(Id, Ids, Quorum, #{})} || Id <- New])),
        store := maps:merge(Store, maps:from_list([{Id, #{entries => #{}}} || Id <- New]))
    }.

members(Id, S) -> peace_core:members(core(Id, S)).

restart(Id, S = #{ids := Ids, quorum := Quorum, cores := Cores, store := Store}) ->
    S#{cores := Cores#{Id := start(Id, Ids, Quorum, maps:get(Id, Store))}}.

%% Sets every server's clock, in milliseconds.
at(Now, S) ->
    S#{now => Now}.

%% Replaces the set of one-way links that lose everything sent on them.
block(Pairs, S) ->
    S#{blocked := Pairs}.

ev(Id, Event, S = #{cores := Cores}) ->
    {Core, Effects} = peace_core:handle(Event, maps:get(now, S, 0), maps:get(Id, Cores)),
    ok = persist_precedes_what_depends_on_it(Effects),
    lists:foldl(fun(E, Acc) -> effect(Id, E, Acc) end, S#{cores := Cores#{Id := Core}}, Effects).

effect(Id, {send, To, Msg}, S0 = #{net := Net, blocked := Blocked}) ->
    %% Everything sent, delivered or not, newest first.
    S = S0#{sent => [{Id, To, Msg} | maps:get(sent, S0, [])]},
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
    Entries1 = maps:merge(Entries0, maps:from_list(maps:get(entries, Batch, []))),
    Stored2 = maps:merge(Stored1, maps:with([snapshot], Batch)),
    {Floor, _} = maps:get(snapshot, Stored2, {0, none}),
    Stored3 = Stored2#{entries := maps:filter(fun(I, _) -> I > Floor end, Entries1)},
    S#{store := Store#{Id := Stored3}};
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

%% Who `From' has sent index `I' to, in an accept.
sent_index(From, I, S) ->
    lists:usort([
        To
     || {F, To, {propose, _Epoch, Entries, _Commit, _Stamp}} <- maps:get(sent, S, []),
        F =:= From,
        lists:keymember(I, 1, Entries)
    ]).

preferred(Id, S) -> maps:get(preferred, peace_core:overview(core(Id, S))).

core(Id, #{cores := Cores}) -> maps:get(Id, Cores).
role(Id, S) -> peace_core:role(core(Id, S)).
commit(Id, S) -> peace_core:commit_index(core(Id, S)).
promised(Id, S) -> peace_core:promised(core(Id, S)).
learned(Id, S) -> peace_core:learned(core(Id, S)).
kv(Id, S) -> maps:get(kv, peace_core:machine_state(core(Id, S))).
stored(Id, #{store := Store}) -> maps:get(Id, Store).
replies(#{replies := Replies}) -> Replies.
