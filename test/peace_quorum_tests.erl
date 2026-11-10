-module(peace_quorum_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M(N), lists:seq(1, N)).

majority_test() ->
    ?assertEqual(ok, peace_quorum:validate(majority, ?M(5))),
    ?assert(peace_quorum:is_phase_one_quorum(majority, ?M(5), [1, 2, 3])),
    ?assertNot(peace_quorum:is_phase_two_quorum(majority, ?M(5), [1, 2])),
    %% Half is not a majority.
    ?assertNot(peace_quorum:is_phase_two_quorum(majority, ?M(4), [1, 2])),
    %% Strangers and duplicates do not count.
    ?assertNot(peace_quorum:is_phase_one_quorum(majority, ?M(5), [1, 1, 2, 9, 10])).

counting_test() ->
    Spec = {counting, 4, 2},
    ?assertEqual(ok, peace_quorum:validate(Spec, ?M(5))),
    ?assert(peace_quorum:is_phase_two_quorum(Spec, ?M(5), [4, 5])),
    ?assertNot(peace_quorum:is_phase_one_quorum(Spec, ?M(5), [1, 2, 3])),
    ?assert(peace_quorum:is_phase_one_quorum(Spec, ?M(5), [1, 2, 3, 4])).

counting_must_intersect_test() ->
    ?assertMatch(
        {error, {quorums_do_not_intersect, #{phase_one := _, phase_two := _}}},
        peace_quorum:validate({counting, 3, 2}, ?M(5))
    ),
    ?assertMatch(
        {error, {quorum_size_out_of_range, _, 3}},
        peace_quorum:validate({counting, 4, 1}, ?M(3))
    ),
    %% All for phase one buys single-member replication.
    ?assertEqual(ok, peace_quorum:validate({counting, 3, 1}, ?M(3))).

%% The thesis's named points on the counting line (sections 4.3.2, 4.3.3).
named_counting_systems_test() ->
    %% Even nodes: half the cluster commits, where a majority needs one more.
    Even = {counting, 3, 2},
    ?assertEqual(ok, peace_quorum:validate(Even, ?M(4))),
    ?assert(peace_quorum:is_phase_two_quorum(Even, ?M(4), [1, 2])),
    ?assertNot(peace_quorum:is_phase_two_quorum(majority, ?M(4), [1, 2])),
    %% Singleton Paxos and All aboard Paxos.
    ?assertEqual(ok, peace_quorum:validate({counting, 5, 1}, ?M(5))),
    ?assertEqual(ok, peace_quorum:validate({counting, 1, 5}, ?M(5))),
    ?assert(peace_quorum:is_phase_one_quorum({counting, 1, 5}, ?M(5), [3])),
    ?assertNot(peace_quorum:is_phase_two_quorum({counting, 1, 5}, ?M(5), [1, 2, 3, 4])).

%% The thesis's running example for revision A (section 4.1.3): four
%% acceptors, phase one on rows and phase two on columns, or the other way round.
%% Either is a grid here, and the minimum the intersection rule allows.
thesis_grid_example_test() ->
    Spec = {grid, [[a1, a3], [a2, a4]]},
    Members = [a1, a2, a3, a4],
    ?assertEqual(ok, peace_quorum:validate(Spec, Members)),
    ?assert(peace_quorum:is_phase_two_quorum(Spec, Members, [a1, a3])),
    ?assert(peace_quorum:is_phase_two_quorum(Spec, Members, [a2, a4])),
    ?assert(peace_quorum:is_phase_one_quorum(Spec, Members, [a1, a2])),
    ?assert(peace_quorum:is_phase_one_quorum(Spec, Members, [a3, a4])),
    ?assertNot(peace_quorum:is_phase_one_quorum(Spec, Members, [a1, a3])).

grid_test() ->
    Rows = [[1, 2, 3], [4, 5, 6]],
    Spec = {grid, Rows},
    ?assertEqual(ok, peace_quorum:validate(Spec, ?M(6))),
    %% Phase two: one whole row. Two rows are disjoint and both are quorums.
    ?assert(peace_quorum:is_phase_two_quorum(Spec, ?M(6), [1, 2, 3])),
    ?assert(peace_quorum:is_phase_two_quorum(Spec, ?M(6), [4, 5, 6])),
    ?assertNot(peace_quorum:is_phase_two_quorum(Spec, ?M(6), [1, 2, 4, 5])),
    %% Phase one: one from every row.
    ?assert(peace_quorum:is_phase_one_quorum(Spec, ?M(6), [3, 4])),
    ?assertNot(peace_quorum:is_phase_one_quorum(Spec, ?M(6), [1, 2, 3])),
    ?assertMatch(
        {error, {grid_rows_must_partition_members, _}},
        peace_quorum:validate({grid, [[1, 2], [3]]}, ?M(4))
    ).

large_cluster_uses_arithmetic_test() ->
    ?assertEqual(ok, peace_quorum:validate({counting, 20, 2}, ?M(21))),
    ?assertMatch(
        {error, {quorums_do_not_intersect, {counting, 10, 11}}},
        peace_quorum:validate({counting, 10, 11}, ?M(21))
    ).

malformed_test() ->
    ?assertMatch({error, {invalid_members, _}}, peace_quorum:validate(majority, [])),
    ?assertMatch({error, {invalid_members, _}}, peace_quorum:validate(majority, [1, 1])),
    ?assertMatch({error, {unknown_quorum_spec, _}}, peace_quorum:validate(most, ?M(3))).

%% Exhaustive validation agrees with the arithmetic for every counting system
%% up to seven members.
exhaustive_matches_arithmetic_test() ->
    [
        ?assertEqual(
            Q1 + Q2 > N,
            peace_quorum:validate({counting, Q1, Q2}, ?M(N)) =:= ok,
            {N, Q1, Q2}
        )
     || N <- lists:seq(1, 7), Q1 <- lists:seq(1, N), Q2 <- lists:seq(1, N)
    ].
