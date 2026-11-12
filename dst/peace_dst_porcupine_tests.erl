%% This suite checks the client histories of simulated runs with Porcupine,
%% a linearizability checker that shares no code with peace. `make
%% porcupine' runs the suite. The suite needs Go. `make dst' does not need
%% Go.
%%
%% `peace_dst' checks the same property with its own invariants. Porcupine
%% is an independent check of those invariants. See `peace_dst_history' for
%% the history and `dst/porcupine/main.go' for the model.
-module(peace_dst_porcupine_tests).

-include_lib("eunit/include/eunit.hrl").

-export([check/3]).

-define(TIMEOUT, 1800).

%% Runs one seed, writes the history of the run to
%% `_build/histories/Name.json' and runs Porcupine on the history. Returns
%% `{ok | illegal | error, Outcome, Operations, Output}'. `Outcome' is the
%% verdict of the invariants of the simulation.
check(Name, Seed, Config) ->
    Table = ets:new(peace_dst_history, [public, ordered_set]),
    Result = eta_run:run(peace_dst, peace_dst_tests:opts(Seed, Config#{history => Table})),
    Events = peace_dst_history:events(Table),
    true = ets:delete(Table),
    File = filename:join(["_build", "histories", Name ++ ".json"]),
    ok = peace_dst_history:write(File, Events),
    Output = os:cmd("dst/check_history.sh " ++ File ++ " 2>&1"),
    {Verdict, Operations} =
        case string:lexemes(Output, " \n") of
            ["ok", N, "operations"] -> {ok, list_to_integer(N)};
            ["ILLEGAL", N, "operations"] -> {illegal, list_to_integer(N)};
            _ -> {error, 0}
        end,
    {Verdict, maps:get(outcome, Result), Operations, Output}.

%% Every run must be linearizable according to Porcupine and correct
%% according to the invariants. Returns the number of operations checked.
sweep(Prefix, Seeds, Config) ->
    lists:sum([
        begin
            {Verdict, Outcome, Operations, Output} = check(Prefix ++ "-" ++ integer_to_list(Seed), Seed, Config),
            ?assertEqual({ok, ok}, {Verdict, Outcome}, {seed, Seed, Output}),
            Operations
        end
     || Seed <- Seeds
    ]).

%% Returns the first seed whose history Porcupine rejects, with the verdict
%% of the invariants for that seed.
first_illegal(_Prefix, [], _Config) ->
    error(no_seed_produced_a_history_that_porcupine_rejects);
first_illegal(Prefix, [Seed | Seeds], Config) ->
    case check(Prefix ++ "-" ++ integer_to_list(Seed), Seed, Config) of
        {illegal, Outcome, _Operations, _Output} -> {Seed, Outcome};
        {ok, _Outcome, _Operations, _Output} -> first_illegal(Prefix, Seeds, Config);
        {error, _Outcome, _Operations, Output} -> error({porcupine_failed, Seed, Output})
    end.

%% Crashes, restarts and network cuts.
faults_test_() ->
    {timeout, ?TIMEOUT, fun() -> exercised(sweep("faults", lists:seq(1, 40), #{})) end}.

%% Forced elections, two-server partitions and delayed `learned' messages.
churn_test_() ->
    {timeout, ?TIMEOUT, fun() -> exercised(sweep("churn", lists:seq(1, 30), #{servers => 5, churn => true})) end}.

%% Five servers with the quorum system `{counting, 4, 2}'.
flexible_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        exercised(sweep("flexible", lists:seq(1, 30), #{servers => 5, quorum => {counting, 4, 2}}))
    end}.

%% Read leases, with the clocks of two servers in three running six per
%% cent fast.
leases_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        Config = #{servers => 3, churn => true, read_lease_ms => 200, election_timeout_ms => 200, clock_drift => 6},
        exercised(sweep("leases", lists:seq(1, 30), Config))
    end}.

%% Membership change between five configurations of five servers.
membership_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        exercised(sweep("membership", lists:seq(1, 30), #{servers => 5, reconfigure => true}))
    end}.

%% The following tests show that Porcupine can reject a history. Each test
%% plants a bug and searches for a seed whose history Porcupine rejects.

%% Clients retry without a session, so a value is applied twice. A read then
%% returns the value twice.
bare_retries_are_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Outcome} = first_illegal("bare-retries", lists:seq(1, 300), #{mode => bare_retries}),
        ?debugFmt("bare retries: seed ~b, invariants ~0p", [Seed, element(1, Outcome)]),
        %% With sessions, the same seed is linearizable.
        ?assertMatch({ok, ok, _, _}, check("bare-retries-fixed", Seed, #{}))
    end}.

%% Acceptors ignore read leases, so a leader that was deposed answers a read
%% from stale state.
missing_lease_fence_is_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        Config = #{servers => 3, churn => true, read_lease_ms => 200, election_timeout_ms => 200},
        {Seed, Outcome} = first_illegal("no-lease-fence", lists:seq(1, 300), Config#{mode => no_lease_fence}),
        ?debugFmt("no lease fence: seed ~b, invariants ~0p", [Seed, element(1, Outcome)]),
        ?assertMatch({ok, ok, _, _}, check("no-lease-fence-fixed", Seed, Config))
    end}.

%% Quorums that do not intersect, so two leaders decide different values at
%% one index.
unsafe_quorums_are_rejected_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Outcome} = first_illegal("unsafe-quorums", lists:seq(1, 300), #{mode => unsafe_quorums}),
        ?debugFmt("unsafe quorums: seed ~b, invariants ~0p", [Seed, element(1, Outcome)])
    end}.

%% Asserts that the sweep checked a useful number of operations.
exercised(Operations) ->
    ?debugFmt("operations checked: ~b", [Operations]),
    ?assert(Operations > 500, Operations).
