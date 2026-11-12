%% This suite validates traces of simulated runs against
%% `formal/FlexiblePaxos.tla'. `make trace' runs the suite. The suite needs
%% Java to run TLC. `make dst' does not need Java.
%% See `peace_dst_trace' for the actions that are derived from a run and for
%% the meaning of a pass.
-module(peace_dst_trace_tests).

-include_lib("eunit/include/eunit.hrl").

-export([validate/3]).

-define(TIMEOUT, 1800).

%% Runs one seed, writes the trace of the run under `_build/traces/Name' and
%% runs TLC on the trace. Returns
%% `{accepted | rejected | error, Outcome, Counts, Output}'.
validate(Name, Seed, Config) ->
    Table = ets:new(peace_dst_trace, [public, ordered_set]),
    Opts = peace_dst_tests:opts(Seed, Config#{trace => Table}),
    Result = eta_run:run(peace_dst, Opts),
    Steps = peace_dst_trace:steps(Table),
    true = ets:delete(Table),
    N = maps:get(servers, Config, 3),
    Ids = [peace_dst:id(I) || I <- lists:seq(1, N)],
    Quorum =
        case maps:get(mode, Config, correct) of
            %% The trace is validated against the quorums that a correct
            %% cluster of this size has.
            unsafe_quorums -> majority;
            _ -> maps:get(quorum, Config, majority)
        end,
    Actions = peace_dst_trace:actions(Steps, Ids),
    Dir = filename:join(["_build", "traces", Name]),
    ok = peace_dst_trace:write(Dir, Actions, Ids, Quorum),
    Output = os:cmd("formal/check_trace.sh " ++ Dir ++ " 2>&1"),
    Verdict =
        case Output of
            "accepted" ++ _ -> accepted;
            "REJECTED" ++ _ -> rejected;
            _ -> error
        end,
    {Verdict, maps:get(outcome, Result), peace_dst_trace:counts(Actions), Output}.

sweep(Prefix, Seeds, Config) ->
    lists:foldl(
        fun(Seed, Acc) ->
            Name = Prefix ++ "-" ++ integer_to_list(Seed),
            {Verdict, Outcome, Counts, Output} = validate(Name, Seed, Config),
            ?assertEqual({accepted, ok}, {Verdict, Outcome}, {seed, Seed, Output}),
            maps:merge_with(fun(_K, A, B) -> A + B end, Acc, Counts)
        end,
        #{},
        Seeds
    ).

%% Asserts that the runs produced every action of the model.
exercised(Counts) ->
    ?debugFmt("actions validated: ~0p", [Counts]),
    [
        ?assert(maps:get(Act, Counts, 0) > 0, {never, Act, Counts})
     || Act <- [prepare, promise, propose, accept, leader_learn, send_commit, follower_commit, catchup, snapshot]
    ],
    ?assertEqual(0, maps:get(invalid, Counts, 0)).

%% This test validates runs of the faults workload: crashes, restarts and
%% network cuts.
faults_are_behaviours_of_the_model_test_() ->
    {timeout, ?TIMEOUT, fun() -> exercised(sweep("faults", lists:seq(1, 20), #{})) end}.

%% This test validates runs of the churn workload: forced elections, splits
%% and rumours. The churn workload is the stale-leader workload.
churn_is_a_behaviour_of_the_model_test_() ->
    {timeout, ?TIMEOUT, fun() -> exercised(sweep("churn", lists:seq(1, 20), #{churn => true})) end}.

%% This test validates runs with five servers. Two servers are needed to
%% decide and four servers are needed to elect.
flexible_quorums_are_behaviours_of_the_model_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        exercised(sweep("flexible", lists:seq(1, 10), #{servers => 5, quorum => {counting, 4, 2}}))
    end}.

%% ---------------------------------------------------------------------------
%% Planted bugs. These tests show that validation can reject a run. Each
%% planted bug is a mode of `peace_dst'. The model rejects some runs that
%% pass the invariants of the simulation. In such a run the planted bug has
%% taken effect but has not yet violated an invariant.
%% ---------------------------------------------------------------------------

%% Returns `{Rejected, Violated}': the number of runs that the model
%% rejected, and the number of runs that violated the invariants of the
%% simulation.
planted(Prefix, Seeds, Config) ->
    lists:foldl(
        fun(Seed, {Rejected, Violated}) ->
            Name = Prefix ++ "-" ++ integer_to_list(Seed),
            {Verdict, Outcome, _Counts, Output} = validate(Name, Seed, Config),
            ?assertNotEqual(error, Verdict, {seed, Seed, Output}),
            %% The model rejects every run that violates an invariant.
            ?assert(Outcome =:= ok orelse Verdict =:= rejected, {seed, Seed, Outcome}),
            {
                Rejected + length([x || Verdict =:= rejected]),
                Violated + length([x || Outcome =/= ok])
            }
        end,
        {0, 0},
        Seeds
    ).

%% The servers need two servers to elect and one server to decide. The trace
%% is validated against majority quorums. A leader treats one accept as a
%% decision, and the model holds no quorum of accepts for that decision.
unsafe_quorums_are_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted("unsafe-quorums", lists:seq(1, 30), #{mode => unsafe_quorums}),
        ?debugFmt("unsafe quorums: model rejected ~b of 30, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 20 andalso Rejected > Violated, {Rejected, Violated})
    end}.

%% The disk of a server loses its contents on restart. A promise then
%% decreases, and no action of the model decreases a promise.
amnesia_is_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted("amnesia", lists:seq(1, 30), #{mode => amnesia}),
        ?debugFmt("amnesia: model rejected ~b of 30, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 10, {Rejected, Violated})
    end}.

%% A candidate becomes leader on a promise from an acceptor that has dropped,
%% under a snapshot, indexes that the candidate never learned.
no_snapshot_guard_is_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted("no-snapshot-guard", lists:seq(1, 60), #{mode => no_snapshot_guard}),
        ?debugFmt("no snapshot guard: model rejected ~b of 60, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 1, {Rejected, Violated})
    end}.

%% A contradicted leader continues to lead. The invariants need hundreds of
%% seeds before a run violates an invariant. The model rejects the first
%% proposal that the leader makes for an index that the leader has been told
%% is decided.
no_conflict_step_down_is_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted(
            "no-conflict-step-down", lists:seq(1, 60), #{mode => no_conflict_step_down, churn => true}
        ),
        ?debugFmt("no conflict step-down: model rejected ~b of 60, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 1, {Rejected, Violated})
    end}.
