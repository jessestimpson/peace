%% These tests run the protocol without processes. The test state holds the
%% cores in a map and the messages in a queue. The test decides whether each
%% message is delivered, dropped or held.
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

%% The leader a proposes a value. One follower, b, accepts the value, and the
%% value is not decided. The value must still be recovered after a stops
%% leading, because the phase-one quorum of the next leader may include the
%% follower that accepted the value. The test isolates a and elects b. The
%% test asserts that b and then a learn the value.
new_leader_recovers_accepted_value_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    %% Only b receives the propose. The accept that b sends to a is lost.
    S1 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, c}, {b, a}], S0))),
    ?assertEqual([], replies(S1)),
    ?assertEqual(0, commit(a, S1)),
    %% a is isolated. b becomes leader with the promise from c. b then
    %% proposes again the value that b holds.
    S2 = run(ev(b, force_election, block([{a, b}, {a, c}, {b, a}, {c, a}], S1))),
    ?assertEqual(leader, role(b, S2)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, learned(b, S2)),
    %% a is reconnected. The higher epoch stops a from leading, and a becomes
    %% a follower. a then learns the decided value.
    S3 = run(ev(b, heartbeat_timeout, run(ev(b, heartbeat_timeout, block([], S2))))),
    ?assertEqual(follower, role(a, S3)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, learned(a, S3)),
    %% The reply to the original caller says that the outcome is unknown. The
    %% reply does not say that the value failed.
    ?assertEqual([{c1, {error, leadership_lost}}], replies(S3)).

%% A new leader proposes a no-op in each index for which no server reported
%% a value. Later indexes can then be applied.
gaps_are_filled_with_noops_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    %% Index 1 reaches no other server. Index 2 reaches b.
    S1 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, b}, {a, c}], S0))),
    S2 = run(ev(a, {value, c2, {put, k, 2}}, block([{a, c}, {b, a}], S1))),
    S3 = run(ev(b, force_election, block([{a, b}, {a, c}, {b, a}, {c, a}], S2))),
    ?assertEqual(#{1 => noop, 2 => {usr, {put, k, 2}}}, learned(b, S3)),
    ?assertEqual(#{k => 2}, kv(b, S3)).

%% The quorum system is {counting, 3, 1}. An election needs every member.
%% A commit needs one member.
flexible_quorum_commits_alone_test() ->
    S0 = new([a, b, c], {counting, 3, 1}),
    %% Two promises are not a phase-one quorum in this quorum system.
    S1 = run(ev(a, force_election, block([{a, c}], S0))),
    ?assertEqual(candidate, role(a, S1)),
    S2 = run(ev(a, force_election, block([], S1))),
    ?assertEqual(leader, role(a, S2)),
    %% No other server receives the value. The value is still decided.
    S3 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, b}, {a, c}], S2))),
    ?assertEqual([{c1, {ok, ok, a}}], replies(S3)),
    %% Deciding the value alone is safe only because no server can be elected
    %% without a.
    S4 = run(ev(b, force_election, block([{a, b}, {b, a}], S3))),
    ?assertEqual(candidate, role(b, S4)).

%% This test runs the counterexample of formal/FPaxosNoConflictStepDown.cfg
%% against the code.
%%
%% The steps are:
%%   1. a becomes leader in epoch 1. a proposes X, and only b receives X.
%%   2. c, d and e continue without a and b. c, d and e decide Y in the same
%%      index.
%%   3. a still has the leader role. a learns the decided value for the index
%%      through a catch-up.
%%
%% The hazard is the following. If a stayed leader, the commit index of a
%% would cover the index. b holds X from the epoch of a, so b would treat
%% that commit index as "X was decided".
%%
%% The test asserts that a becomes a follower in step 3, that the caller
%% that proposed X is told leadership_lost, that a learns Y and that b
%% learns nothing.
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
    %% This message is an answer to a catch-up request. a sent the request
    %% before a became leader, and the answer arrives late.
    {learned, Y} = maps:get(1, maps:get(entries, stored(c, S3))),
    S4 = run(ev(a, {msg, c, {learned, [{1, Y}]}}, S3)),
    ?assertEqual(follower, role(a, S4)),
    ?assertEqual({error, leadership_lost}, proplists:get_value(cx, replies(S4))),
    S5 = run(ev(a, heartbeat_timeout, block([{b, a}], S4))),
    ?assertEqual(#{}, learned(b, S5)),
    ?assertEqual(#{1 => {usr, {put, k, y}}}, learned(a, S5)).

%% This test covers the same hazard as
%% deposed_leader_steps_down_on_conflict_test, with the two events in the
%% opposite order. The churn workload of the simulation found this case.
%%
%% a learns a decided value for an index in which a has not yet proposed.
%% If a stayed leader, a would propose the next value in that index, over
%% the decided entry. b would then treat the commit index of a as covering
%% that value.
%%
%% The test asserts that a becomes a follower, that a answers a later value
%% with not_leader, that a learns the decided value and that b learns
%% nothing.
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

%% A server stores every promise and every accepted value before the server
%% reports the promise or the accept to another server. A restart from that
%% storage rebuilds the machine. The test restarts b and asserts the role,
%% the commit index and the machine state of b.
restart_recovers_from_storage_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, heartbeat_timeout, run(ev(a, {value, c2, {put, j, 2}}, S1)))),
    S3 = restart(b, S2),
    ?assertEqual(follower, role(b, S3)),
    ?assertEqual(2, commit(b, S3)),
    ?assertEqual(#{k => 1, j => 2}, kv(b, S3)),
    %% The restart also recovered the promise of b. b refuses a prepare with
    %% an epoch below the promised epoch.
    S4 = ev(b, {msg, c, {prepare, {0, c}, 1}}, S3),
    ?assertMatch([{b, c, {nack, {1, a}}}], queue:to_list(maps:get(net, S4))).

consistent_query_is_ordered_by_the_log_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, S1)),
    ?assertEqual({ok, #{k => 1}, a}, proplists:get_value(q1, replies(S2))),
    %% The query used one index. The query changed no state.
    ?assertEqual(#{1 => {usr, {put, k, 1}}, 2 => noop}, learned(a, S2)).

%% a is the leader of epoch 1 and is isolated. b becomes the leader of epoch
%% 2. After a is reconnected, a sends a heartbeat, which is a propose in
%% epoch 1. c has promised epoch 2 and refuses the propose with a nack. a
%% becomes a follower. a learns from the nack which epoch its next campaign
%% must exceed.
nack_teaches_the_next_epoch_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, force_election, run(ev(b, force_election, block([{a, b}, {a, c}, {b, a}, {c, a}], S0))))),
    ?assertEqual(leader, role(b, S1)),
    ?assertEqual({2, b}, promised(c, S1)),
    %% a was isolated and is still the leader of epoch 1. The `force_election'
    %% of a above had no effect, because a is a leader. After a is
    %% reconnected, c refuses the propose that a sends in epoch 1. The nack
    %% from b is lost, because the link from b to a is blocked. The next
    %% campaign of a uses round 3 directly.
    S2 = run(ev(a, heartbeat_timeout, block([{b, a}], S1))),
    ?assertEqual(follower, role(a, S2)),
    S3 = run(ev(a, force_election, block([], S2))),
    ?assertEqual(leader, role(a, S3)),
    ?assertEqual({3, a}, promised(a, S3)).

%% c is isolated and then reconnected. Before c raises the epoch, c asks the
%% other servers whether c may campaign. Every server that still has a leader
%% refuses. The test asserts that the promised epoch does not change, that a
%% stays leader and that c is a follower of a after the reconnection.
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

%% The leader a is unreachable. The steps are:
%%   1. The election timer of b fires first. c has not yet missed the leader,
%%      so c refuses b. b stays a follower.
%%   2. The election timer of c fires. b has already missed the leader, so b
%%      does not refuse c. c becomes leader.
prevote_elects_once_the_leader_is_missed_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    S1 = run(ev(b, election_timeout, block(Gone, S0))),
    ?assertEqual(follower, role(b, S1)),
    ?assertEqual({1, a}, promised(b, S1)),
    S2 = run(ev(c, election_timeout, S1)),
    ?assertEqual(leader, role(c, S2)),
    ?assertEqual({2, c}, promised(b, S2)).

%% A leader steps down when no phase-two quorum answers the leader any more.
%% Every caller that was waiting for a reply from the leader is told that
%% the outcome is unknown.
leader_without_a_quorum_steps_down_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    %% Every follower answered the first heartbeat.
    S1 = run(ev(a, election_timeout, S0)),
    ?assertEqual(leader, role(a, S1)),
    %% An answer from one follower is enough for a majority of three.
    S2 = run(ev(a, election_timeout, run(ev(a, heartbeat_timeout, block([{a, c}], S1))))),
    ?assertEqual(leader, role(a, S2)),
    Alone = [{a, b}, {a, c}],
    S3 = run(ev(a, {value, c1, {put, k, 1}}, block(Alone, S2))),
    S4 = run(ev(a, election_timeout, run(ev(a, heartbeat_timeout, S3)))),
    ?assertEqual(follower, role(a, S4)),
    ?assertEqual([{c1, {error, leadership_lost}}], replies(S4)).

%% The quorum system is {counting, 3, 1}. The leader decides values alone,
%% so the leader never has a reason to step down.
leader_that_commits_alone_never_steps_down_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], {counting, 3, 1}))),
    S1 = run(ev(a, election_timeout, run(ev(a, election_timeout, block([{a, b}, {a, c}], S0))))),
    ?assertEqual(leader, role(a, S1)).

%% When a value is decided twice under one session, the machine applies the
%% value once. The reply to the second copy is the same as the reply to the
%% first copy.
session_applies_once_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {value, c1, {put, k, 1}, {me, 1}}, S0)),
    S2 = run(ev(a, {value, c2, {put, k, 2}}, S1)),
    %% This value is the retry. The retry uses the same session. k is now 2.
    S3 = run(ev(a, {value, c3, {put, k, 1}, {me, 1}}, S2)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c3, replies(S3))),
    ?assertEqual(#{k => 2}, kv(a, S3)),
    ?assertEqual(3, commit(a, S3)),
    %% The next value of the session is a new value.
    S4 = run(ev(a, {value, c4, {put, k, 4}, {me, 2}}, S3)),
    ?assertEqual(#{k => 4}, kv(a, S4)),
    %% A copy of the old value of the session arrives late and is refused.
    S5 = run(ev(a, {value, c5, {put, k, 1}, {me, 1}}, S4)),
    ?assertEqual({error, {session_superseded, 2}}, proplists:get_value(c5, replies(S5))),
    ?assertEqual(#{k => 4}, kv(a, S5)),
    %% The followers reach the same state in the same way.
    S6 = run(ev(a, heartbeat_timeout, S5)),
    ?assertEqual([#{k => 4}, #{k => 4}], [kv(I, S6) || I <- [b, c]]).

%% Sessions are evicted in order of index, with the oldest index first.
%% Every server evicts the same sessions.
sessions_are_bounded_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority, #{max_sessions => 2}))),
    S1 = lists:foldl(
        fun(N, S) -> run(ev(a, {value, N, {put, N, N}, {N, 1}}, S)) end, S0, [1, 2, 3]
    ),
    ?assertMatch(#{sessions := 2}, peace_core:overview(core(a, S1))),
    %% The session of client 1 was evicted, so the retry from client 1 is a
    %% new value.
    S2 = run(ev(a, {value, again, {put, 1, again}, {1, 1}}, S1)),
    ?assertEqual(again, maps:get(1, kv(a, S2))).

%% The log entries up to the snapshot index are dropped. A restart starts
%% from the snapshot.
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
    %% The restart recovered the session table together with the snapshot.
    S3 = run(ev(a, force_election, S2)),
    S4 = run(ev(a, {value, retry, {put, 3, retried}, {me, 3}}, S3)),
    ?assertEqual(3, maps:get(3, kv(a, S4))).

%% A follower can be so far behind that the leader no longer holds the log
%% entries the follower needs. The leader then sends the state to the
%% follower.
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

%% This test runs the counterexample of formal/FPaxosNoSnapshotGuard.cfg
%% against the code.
%%
%% c missed two values. a and b have since dropped those two values from the
%% logs of a and b. The promise from b reports nothing about indexes that b
%% no longer holds. The hazard is the following. If c campaigned on the
%% promise from b, c would:
%%   1. treat those indexes as free,
%%   2. propose other values in those indexes, and
%%   3. count the acknowledgement from b.
%%
%% The test asserts that c stays a follower on the first campaign.
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
    %% Instead, c asked b for the state that c was missing. c may now lead.
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
    %% c treats index 1 as free. b acknowledges any value sent for index 1.
    S4 = run(ev(c, {value, cz, {put, 1, other}}, S3)),
    ?assertEqual({ok, ok, c}, proplists:get_value(cz, replies(S4))),
    ?assertEqual(#{1 => 1, 2 => 2}, kv(a, S4)),
    ?assertEqual(#{1 => other}, kv(c, S4)).

%% With a lease, the leader answers a read without using an index. The
%% leader does this only while no other server can have been elected.
lease_read_takes_no_index_test() ->
    S0 = run(ev(a, force_election, at(100, new([a, b, c], majority, #{read_lease_ms => 100})))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, at(150, S1))),
    ?assertEqual({ok, #{k => 1}, a}, proplists:get_value(q1, replies(S2))),
    ?assertEqual(1, peace_core:last_index(core(a, S2))),
    %% The leader stops trusting the lease ninety milliseconds after the
    %% last answer. That is ten milliseconds before the followers stop
    %% honouring the lease.
    S3 = run(ev(a, {query, q2, fun(#{kv := KV}) -> KV end}, block([{a, b}, {a, c}], at(195, S2)))),
    ?assertEqual(undefined, proplists:get_value(q2, replies(S3))),
    ?assertEqual(2, peace_core:last_index(core(a, S3))).

%% While followers honour the lease, the followers do not promise any other
%% server and do not campaign.
lease_holders_do_not_promise_test() ->
    S0 = run(ev(a, force_election, at(100, new([a, b, c], majority, #{read_lease_ms => 100})))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    S1 = run(ev(b, force_election, block(Gone, at(150, S0)))),
    ?assertEqual([follower, {1, a}], [role(b, S1), promised(b, S1)]),
    S2 = run(ev(c, {msg, b, {prepare, {2, b}, 1}}, S1)),
    ?assertEqual({1, a}, promised(c, S2)),
    %% After the lease has ended, the followers do promise and campaign.
    S3 = run(ev(b, force_election, at(200, S2))),
    ?assertEqual(leader, role(b, S3)).

%% A lease depends on one assumption: the clocks of the servers run within
%% ten per cent of each other. In this test the clocks of the followers run
%% a tenth fast. The followers therefore end the lease early, at 1909 true
%% milliseconds. The leader trusts the lease until 1900 true milliseconds.
lease_holds_with_clocks_a_tenth_apart_test() ->
    Fast = #{b => {11, 10}, c => {11, 10}},
    S0 = run(ev(a, force_election, at(1000, rates(Fast, new([a, b, c], majority, #{read_lease_ms => 1000}))))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    %% This is the last instant at which the leader answers on the lease. At
    %% this instant no server can replace the leader.
    S1 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, block(Gone, at(1899, S0)))),
    ?assertMatch({ok, _, a}, proplists:get_value(q1, replies(S1))),
    S2 = run(ev(b, force_election, S1)),
    ?assertEqual(follower, role(b, S2)),
    %% At the first instant at which a server can replace the leader, the
    %% leader no longer answers on the lease.
    S3 = run(ev(b, force_election, at(1910, S2))),
    ?assertEqual(leader, role(b, S3)),
    S4 = run(ev(a, {query, q2, fun(#{kv := KV}) -> KV end}, at(1900, S2))),
    ?assertEqual(undefined, proplists:get_value(q2, replies(S4))).

%% The lease is safe only if the clock assumption holds. In this test the
%% clocks of the followers run a quarter fast. The test asserts that there
%% is a time at which a follower has been elected and the old leader still
%% answers on the lease.
lease_fails_with_clocks_a_quarter_apart_test() ->
    Fast = #{b => {5, 4}, c => {5, 4}},
    S0 = run(ev(a, force_election, at(1000, rates(Fast, new([a, b, c], majority, #{read_lease_ms => 1000}))))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    S1 = run(ev(b, force_election, block(Gone, at(1850, S0)))),
    ?assertEqual(leader, role(b, S1)),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, S1)),
    ?assertMatch({ok, _, a}, proplists:get_value(q1, replies(S2))).

%% A server that restarts has no record of the lease that the server was
%% honouring. The restarted server therefore honours a full lease.
%%
%% `restart/2' starts a core with `peace_core:init/2', which takes the clock
%% reading as 0. The time that `at/2' set before the restart therefore has
%% no effect on the restarted core. b and c honour a lease of 100
%% milliseconds from 0. The test then sets the time to 60, which is within
%% that lease, and asserts that b does not campaign.
lease_survives_a_restart_test() ->
    S0 = run(ev(a, force_election, at(100, new([a, b, c], majority, #{read_lease_ms => 100})))),
    S1 = restart(c, restart(b, at(150, S0))),
    Gone = [{a, b}, {a, c}, {b, a}, {c, a}],
    S2 = run(ev(b, force_election, block(Gone, at(60, S1)))),
    ?assertEqual(follower, role(b, S2)).

%% The quorum system is {counting, 4, 2} over five members. Only the
%% follower b receives the heartbeat of the leader a and answers it. b is
%% then bound by the lease. The servers that are not bound are c, d and e.
%% A phase-one quorum needs four members, so c, d and e cannot elect a
%% leader. Therefore a answers the query on the lease. a and b are two
%% servers. Two servers are fewer than a majority of five and fewer than a
%% phase-one quorum. Two servers are the size of a phase-two quorum, but
%% the lease does not need that: the lease needs only that the servers that
%% are not bound contain no phase-one quorum.
lease_needs_only_to_block_phase_one_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, at(100, new(Ids, {counting, 4, 2}, #{read_lease_ms => 100})))),
    OnlyB = [{a, c}, {a, d}, {a, e}],
    S1 = run(ev(a, heartbeat_timeout, block(OnlyB, at(300, S0)))),
    S2 = run(ev(a, {query, q1, fun(#{kv := KV}) -> KV end}, at(310, S1))),
    ?assertEqual({ok, #{}, a}, proplists:get_value(q1, replies(S2))),
    ?assertEqual(0, peace_core:last_index(core(a, S2))),
    %% When no follower answers, the leader cannot know whether another
    %% server has been elected. The leader does not answer on the lease.
    S3 = run(ev(a, {query, q2, fun(#{kv := KV}) -> KV end}, block([{a, b} | OnlyB], at(400, S2)))),
    ?assertEqual(undefined, proplists:get_value(q2, replies(S3))).

%% The test replaces every member. The old configuration and the new
%% configuration have no member in common.
change_members_to_a_disjoint_set_test() ->
    S0 = run(ev(a, force_election, join([d, e, f], new([a, b, c], majority)))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    S2 = run(ev(a, {reconfigure, r1, {[d, e, f], majority}}, S1)),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S2))),
    %% a completed the change that removed a. a then stopped leading.
    ?assertEqual(follower, role(a, S2)),
    ?assertEqual({final, {[d, e, f], majority}}, peace_core:config(core(a, S2))),
    %% The new members continue without the old members. The new members
    %% have the values that were decided before the change.
    Old = [{X, Y} || X <- [a, b, c], Y <- [d, e, f]] ++ [{Y, X} || X <- [a, b, c], Y <- [d, e, f]],
    S3 = run(ev(d, force_election, block(Old, S2))),
    ?assertEqual(leader, role(d, S3)),
    S4 = run(ev(d, {value, c2, {put, j, 2}}, S3)),
    ?assertEqual({ok, ok, d}, proplists:get_value(c2, replies(S4))),
    ?assertEqual(#{k => 1, j => 2}, kv(d, S4)),
    ?assertEqual([d, e, f], members(e, run(ev(d, heartbeat_timeout, S4)))),
    %% An old member can no longer become leader.
    S5 = run(ev(b, force_election, block([], S4))),
    ?assertEqual(candidate, role(b, S5)),
    ?assertEqual([leader, {2, d}, {2, d}], [role(d, S5), promised(e, S5), promised(f, S5)]).

%% While the old configuration and the new configuration are both in force,
%% a value is decided only with a quorum of each configuration. The leader
%% refuses a second change during that time.
joint_configuration_needs_both_test() ->
    S0 = run(ev(a, force_election, join([d, e], new([a, b, c], majority)))),
    NoNew = [{a, d}, {a, e}],
    S1 = run(ev(a, {reconfigure, r1, {[a, d, e], majority}}, block(NoNew, S0))),
    ?assertEqual(undefined, proplists:get_value(r1, replies(S1))),
    ?assertEqual({joint, {[a, b, c], majority}, {[a, d, e], majority}}, peace_core:config(core(a, S1))),
    ?assertEqual([a, b, c, d, e], members(a, S1)),
    %% b and c acknowledge. That is a quorum of the old configuration only.
    S2 = run(ev(a, {value, c1, {put, k, 1}}, S1)),
    ?assertEqual(undefined, proplists:get_value(c1, replies(S2))),
    S3 = run(ev(a, {reconfigure, r2, {[a, b], majority}}, S2)),
    ?assertEqual({error, reconfiguration_in_progress}, proplists:get_value(r2, replies(S3))),
    %% An acknowledgement from d is enough for a quorum of the new
    %% configuration.
    S4 = run(ev(a, heartbeat_timeout, run(ev(a, heartbeat_timeout, block([{a, e}], S3))))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S4))),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S4))),
    ?assertEqual({final, {[a, d, e], majority}}, peace_core:config(core(a, S4))).

%% The change of membership is an entry in the log, so the next leader
%% completes the change.
change_survives_its_leader_test() ->
    S0 = run(ev(a, force_election, join([d], new([a, b, c], majority)))),
    %% The joint entry reaches only b. a is then unreachable.
    S1 = run(ev(a, {reconfigure, r1, {[b, c, d], majority}}, block([{a, c}, {a, d}, {b, a}], S0))),
    Gone = [{a, X} || X <- [b, c, d]] ++ [{X, a} || X <- [b, c, d]],
    S2 = run(ev(b, force_election, block(Gone, S1))),
    ?assertEqual(leader, role(b, S2)),
    ?assertEqual({final, {[b, c, d], majority}}, peace_core:config(core(b, S2))),
    S3 = run(ev(b, heartbeat_timeout, S2)),
    ?assertEqual([[b, c, d], [b, c, d]], [members(I, S3) || I <- [c, d]]).

%% This test runs the counterexample of formal/ReconfigNoClosure.cfg against
%% the code.
%%
%% c missed a change of membership. In the new configuration c is one of
%% three members, and c does not know the other two members. c campaigns.
%% The promise from b gives c a quorum of the configuration that c knows.
%% The promise from b also reports the configuration that c does not know.
%% c then needs a quorum of that configuration as well. c asks the servers
%% that the configuration names.
a_promise_raises_the_bar_test() ->
    S0 = run(ev(a, force_election, join([d, e], new([a, b, c], majority)))),
    S1 = run(ev(a, {reconfigure, r1, {[c, d, e], majority}}, block([{a, c}], S0))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    ?assertEqual([a, b, c], members(c, S1)),
    %% Only b answers c.
    Only = [{c, a}, {c, d}, {c, e}],
    S2 = run(ev(c, force_election, block(Only, S1))),
    ?assertEqual(candidate, role(c, S2)),
    %% With a promise from d as well, c has a majority of [c, d, e].
    S3 = run(ev(c, force_election, block([{c, a}, {c, e}], S2))),
    ?assertEqual(leader, role(c, S3)),
    ?assertEqual({final, {[c, d, e], majority}}, peace_core:config(core(c, S3))).

%% c was removed from the configuration and has not received the change.
%% A campaign by c cannot disturb the servers that have received the change.
removed_server_cannot_depose_test() ->
    S0 = run(ev(a, force_election, new([a, b, c], majority))),
    S1 = run(ev(a, {reconfigure, r1, {[a, b], majority}}, block([{a, c}], S0))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    S2 = run(ev(a, heartbeat_timeout, S1)),
    S3 = run(ev(c, force_election, block([], S2))),
    ?assertEqual([leader, {1, a}], [role(a, S3), promised(b, S3)]).

%% The change keeps the members and changes only the quorum system. The
%% quorum system changes from majority to one in which two of the four
%% members commit a value.
change_quorum_system_only_test() ->
    Ids = [a, b, c, d],
    S0 = run(ev(a, force_election, new(Ids, majority))),
    S1 = run(ev(a, {reconfigure, r1, {Ids, {counting, 3, 2}}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    S2 = run(ev(a, {value, c1, {put, k, 1}}, block([{a, c}, {a, d}], S1))),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S2))),
    S3 = run(ev(a, {reconfigure, r2, {Ids, {counting, 2, 2}}}, S2)),
    ?assertMatch({error, {invalid_quorum, _}}, proplists:get_value(r2, replies(S3))).

%% This test runs the counterexample of formal/ReconfigNoJoint.cfg against
%% the code. The leader changes directly to the new configuration, without a
%% joint configuration. The old configuration and the new configuration then
%% each decide a value separately.
without_a_joint_configuration_two_sides_decide_test() ->
    Extra = #{unsafe_no_joint => true},
    S0 = run(ev(a, force_election, join([d], new([a, b, c], majority, Extra)))),
    %% The change reaches only d. d is the whole new configuration.
    S1 = run(ev(a, {reconfigure, r1, {[d], majority}}, block([{a, b}, {a, c}], S0))),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    %% b and c never received the change. b and c are a majority of the old
    %% configuration.
    Apart = [{X, Y} || X <- [b, c], Y <- [a, d]] ++ [{Y, X} || X <- [b, c], Y <- [a, d]],
    S2 = run(ev(b, force_election, block(Apart, S1))),
    S3 = run(ev(b, {value, c1, {put, k, 1}}, S2)),
    ?assertEqual({ok, ok, b}, proplists:get_value(c1, replies(S3))),
    ?assertMatch(#{1 := {cfg, _}}, learned(a, S3)),
    ?assertEqual(#{1 => {usr, {put, k, 1}}}, learned(b, S3)).

%% A commit needs two of the five members. The leader sends each value to
%% one peer. The other three peers learn from the heartbeat that the value
%% exists, and then ask the leader for the value.
propose_to_quorum_sends_to_a_phase_two_quorum_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, new(Ids, {counting, 4, 2}, #{propose_to => quorum}))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S1))),
    ?assertEqual([b], sent_index(a, 1, S1)),
    ?assertEqual([1, 0, 0, 0, 0], [commit(I, S1) || I <- Ids]),
    %% One heartbeat tells the other three peers that the commit index has
    %% moved. The three peers ask for the value and receive the value. A
    %% second heartbeat is not needed.
    S2 = run(ev(a, heartbeat_timeout, S1)),
    ?assertEqual([1, 1, 1, 1, 1], [commit(I, S2) || I <- Ids]),
    ?assertEqual([b], sent_index(a, 1, S2)),
    ?assertEqual(lists:duplicate(5, #{k => 1}), [kv(I, S2) || I <- Ids]).

%% A majority of five members is the leader and two peers.
propose_to_quorum_majority_test() ->
    Ids = [a, b, c, d, e],
    S0 = run(ev(a, force_election, new(Ids, majority, #{propose_to => quorum}))),
    S1 = run(ev(a, {value, c1, {put, k, 1}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S1))),
    ?assertEqual([b, c], sent_index(a, 1, S1)).

%% A grid quorum system is not defined by a count of members. The leader is
%% c. The other row, a and b, is also a quorum, and a greedy choice would
%% find that quorum first. d alone is the smaller set of peers. The test
%% asserts that c sends the value to d only.
propose_to_quorum_grid_test() ->
    Grid = {grid, [[a, b], [c, d]]},
    S0 = run(ev(c, force_election, new([a, b, c, d], Grid, #{propose_to => quorum}))),
    S1 = run(ev(c, {value, c1, {put, k, 1}}, S0)),
    ?assertEqual({ok, ok, c}, proplists:get_value(c1, replies(S1))),
    ?assertEqual([d], sent_index(c, 1, S1)).

%% The peer that the leader prefers is unreachable. The steps are:
%%   1. The leader sends the index to the preferred peer only. The index is
%%      not sent to any other peer on the first heartbeat.
%%   2. On the second heartbeat the leader sends the index to every peer.
%%   3. The leader then prefers a different peer.
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
    %% b has not answered since the timer last fired. The other peers have
    %% answered.
    S5 = run(ev(a, election_timeout, S4)),
    ?assertEqual([c], preferred(a, S5)),
    S6 = run(ev(a, {value, c2, {put, k, 2}}, S5)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c2, replies(S6))),
    ?assertEqual([c], sent_index(a, 2, S6)).

%% During a change of membership, the leader sends a value to a quorum of
%% the old configuration and a quorum of the new configuration.
propose_to_quorum_follows_the_configuration_test() ->
    S0 = run(ev(a, force_election, join([d, e], new([a, b, c], majority, #{propose_to => quorum})))),
    S1 = run(ev(a, {reconfigure, r1, {[a, d, e], majority}}, S0)),
    ?assertEqual({ok, ok, a}, proplists:get_value(r1, replies(S1))),
    %% The leader sent the joint entry to one member of the old configuration
    %% and one member of the new configuration.
    ?assertEqual([b, d], sent_index(a, 1, S1)),
    S2 = run(ev(a, {value, c1, {put, k, 1}}, S1)),
    ?assertEqual({ok, ok, a}, proplists:get_value(c1, replies(S2))),
    ?assertEqual([d], sent_index(a, 3, S2)).

%% ---------------------------------------------------------------------------
%% Test helpers: a simulated network held in a map
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

%% Starts servers that are not members of the cluster. Each new server is
%% configured with the members of the cluster.
join(New, S = #{ids := Ids, quorum := Quorum, cores := Cores, store := Store}) ->
    S#{
        cores := maps:merge(Cores, maps:from_list([{Id, start(Id, Ids, Quorum, #{})} || Id <- New])),
        store := maps:merge(Store, maps:from_list([{Id, #{entries => #{}}} || Id <- New]))
    }.

members(Id, S) -> peace_core:members(core(Id, S)).

restart(Id, S = #{ids := Ids, quorum := Quorum, cores := Cores, store := Store}) ->
    S#{cores := Cores#{Id := start(Id, Ids, Quorum, maps:get(Id, Store))}}.

%% Sets the true time. The unit is milliseconds. A server reads the time
%% when it handles its next event. A restarted server has clock 0 until
%% then.
at(Now, S) ->
    S#{now => Now}.

%% Gives servers clocks that run at `{Num, Den}' times the true rate. `at/2'
%% sets the true time. Each server reads the true time through the clock of
%% that server.
rates(Rates, S) ->
    S#{rates => Rates}.

%% Replaces the set of blocked one-way links. A blocked link loses every
%% message sent on the link.
block(Pairs, S) ->
    S#{blocked := Pairs}.

ev(Id, Event, S = #{cores := Cores}) ->
    {Num, Den} = maps:get(Id, maps:get(rates, S, #{}), {1, 1}),
    {Core, Effects} = peace_core:handle(Event, maps:get(now, S, 0) * Num div Den, maps:get(Id, Cores)),
    ok = persist_precedes_what_depends_on_it(Effects),
    lists:foldl(fun(E, Acc) -> effect(Id, E, Acc) end, S#{cores := Cores#{Id := Core}}, Effects).

effect(Id, {send, To, Msg}, S0 = #{net := Net, blocked := Blocked}) ->
    %% `sent' holds every message sent, whether or not the message is
    %% delivered. The newest message is first.
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

%% Delivers messages until the queue of messages is empty.
run(S = #{net := Net}) ->
    case queue:out(Net) of
        {empty, _} -> S;
        {{value, {From, To, Msg}}, Net1} -> run(ev(To, {msg, From, Msg}, S#{net := Net1}))
    end.

%% Checks that the core lists no persist after the first send in the same
%% list of effects. The function returns an error only in that case. The
%% function does not check the position of a persist relative to a reply.
%% peace_server does not rely on this order, but the order is cheap to
%% keep.
persist_precedes_what_depends_on_it(Effects) ->
    Kinds = [element(1, E) || E <- Effects, lists:member(element(1, E), [persist, send, reply])],
    case lists:dropwhile(fun(K) -> K =:= persist end, Kinds) of
        Rest ->
            case lists:member(persist, lists:dropwhile(fun(K) -> K =/= send end, Rest)) of
                false -> ok;
                true -> {persist_after_send, Effects}
            end
    end.

%% Returns the servers to which `From' has sent index `I' in a propose.
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
