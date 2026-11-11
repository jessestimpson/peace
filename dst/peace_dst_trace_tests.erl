%% Trace validation of simulated runs against `formal/FlexiblePaxos.tla'.
%% `make trace'. Needs Java, for TLC, which `make dst' does not.
%% See `peace_dst_trace' for what is derived from a run and what a pass
%% means.
-module(peace_dst_trace_tests).

-include_lib("eunit/include/eunit.hrl").

-export([validate/3]).

-define(TIMEOUT, 1800).

%% Runs one seed, writes its trace under `_build/traces/Name' and has TLC
%% judge it. `{accepted | rejected | error, Outcome, Counts, Output}'.
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
            %% Held to the quorums a correct cluster of this size would have.
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

%% Every action of the model is something the runs did.
exercised(Counts) ->
    ?debugFmt("actions validated: ~0p", [Counts]),
    [
        ?assert(maps:get(Act, Counts, 0) > 0, {never, Act, Counts})
     || Act <- [prepare, promise, propose, accept, leader_learn, send_commit, follower_commit, catchup, snapshot]
    ],
    ?assertEqual(0, maps:get(invalid, Counts, 0)).

%% Crashes, restarts and cuts.
faults_are_behaviours_of_the_model_test_() ->
    {timeout, ?TIMEOUT, fun() -> exercised(sweep("faults", lists:seq(1, 20), #{})) end}.

%% Forced elections, splits and rumours: the stale-leader workload.
churn_is_a_behaviour_of_the_model_test_() ->
    {timeout, ?TIMEOUT, fun() -> exercised(sweep("churn", lists:seq(1, 20), #{churn => true})) end}.

%% Five servers, two to decide and four to elect.
flexible_quorums_are_behaviours_of_the_model_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        exercised(sweep("flexible", lists:seq(1, 10), #{servers => 5, quorum => {counting, 4, 2}}))
    end}.

%% ---------------------------------------------------------------------------
%% Planted bugs: validation has to be able to say no. Each is a mode of
%% `peace_dst'. The model refuses some runs the simulation's own invariants
%% pass: a run in which the bug has acted but has not yet done harm.
%% ---------------------------------------------------------------------------

%% `{Rejected, Violated}': how many runs the model refused, and how many the
%% simulation's invariants did.
planted(Prefix, Seeds, Config) ->
    lists:foldl(
        fun(Seed, {Rejected, Violated}) ->
            Name = Prefix ++ "-" ++ integer_to_list(Seed),
            {Verdict, Outcome, _Counts, Output} = validate(Name, Seed, Config),
            ?assertNotEqual(error, Verdict, {seed, Seed, Output}),
            %% What the invariants catch, the model catches.
            ?assert(Outcome =:= ok orelse Verdict =:= rejected, {seed, Seed, Outcome}),
            {
                Rejected + length([x || Verdict =:= rejected]),
                Violated + length([x || Outcome =/= ok])
            }
        end,
        {0, 0},
        Seeds
    ).

%% Two to elect and one to decide, held to a majority: a leader counts one
%% acceptance as a decision, and the model has no quorum to show for it.
unsafe_quorums_are_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted("unsafe-quorums", lists:seq(1, 30), #{mode => unsafe_quorums}),
        ?debugFmt("unsafe quorums: model rejected ~b of 30, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 20 andalso Rejected > Violated, {Rejected, Violated})
    end}.

%% A disk that forgets: a promise falls, which no action of the model does.
amnesia_is_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted("amnesia", lists:seq(1, 30), #{mode => amnesia}),
        ?debugFmt("amnesia: model rejected ~b of 30, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 10, {Rejected, Violated})
    end}.

%% A candidate that leads from behind a snapshot.
no_snapshot_guard_is_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted("no-snapshot-guard", lists:seq(1, 60), #{mode => no_snapshot_guard}),
        ?debugFmt("no snapshot guard: model rejected ~b of 60, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 1, {Rejected, Violated})
    end}.

%% A contradicted leader that goes on leading. The invariants need hundreds
%% of seeds to see harm come of it; the model refuses the first proposal it
%% makes over an index it has been told is decided.
no_conflict_step_down_is_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Rejected, Violated} = planted(
            "no-conflict-step-down", lists:seq(1, 60), #{mode => no_conflict_step_down, churn => true}
        ),
        ?debugFmt("no conflict step-down: model rejected ~b of 60, invariants ~b", [Rejected, Violated]),
        ?assert(Rejected >= 1, {Rejected, Violated})
    end}.
