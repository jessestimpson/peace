%% The simulation suite. `make dst', which is `rebar3 as dst eunit' on one
%% scheduler thread; see the Makefile for why.
-module(peace_dst_tests).

-include_lib("eunit/include/eunit.hrl").

-export([opts/2]).

-define(TIMEOUT, 600).

opts(Seed, Config) ->
    #{
        seed => Seed,
        config => Config,
        max_ops => 120,
        max_steps => 60000,
        settle_steps => 4000,
        %% When nothing is runnable, let time pass more often than not:
        %% elections and retransmissions only happen on the clock.
        op_p => 0.15,
        quiet_p => 0.8,
        preload => [peace],
        net => #{policy => #{drop_p => 0.03, delay_p => 0.2, max_delay => 5}}
    }.

calm(Seed, Config) ->
    (opts(Seed, Config#{faults => false, converge => true}))#{net => true}.

run(Opts) ->
    eta_run:run(peace_dst, Opts).

%% A seed is a run: same trace every time, and the recorded trace replays.
determinism_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        lists:foreach(
            fun(Seed) ->
                Opts = opts(Seed, #{}),
                [First | _] = Results = [run(Opts) || _ <- lists:seq(1, 3)],
                ?assertEqual(
                    1,
                    length(lists:usort([maps:get(trace, R) || R <- Results])),
                    {seed, Seed, [eta_run:summary(R) || R <- Results]}
                ),
                ?assertEqual(ok, eta_run:audit(First), {seed, Seed, eta_run:summary(First)}),
                Replayed = eta_run:replay(peace_dst, maps:get(trace, First), Opts),
                ?assertEqual(
                    {maps:get(outcome, First), 0},
                    {maps:get(outcome, Replayed), maps:get(skipped, Replayed)},
                    {seed, Seed}
                )
            end,
            [1, 2, 3]
        )
    end}.

%% No faults at all: every server ends with the same log, and clients were
%% answered.
calm_cluster_converges_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 20), fun(Seed) -> calm(Seed, #{}) end),
        #{acknowledged := Acked, runs := 20} = Stats = peace_dst:stats(),
        ?assert(Acked >= 20 * 40, Stats)
    end}.

%% Loss, delay, isolation, crashes and restarts, majority quorums.
faults_majority_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 100), fun(Seed) -> opts(Seed, #{}) end),
        exercised(peace_dst:stats())
    end}.

%% Five servers, two to commit and four to elect.
faults_flexible_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 60), fun(Seed) ->
            opts(Seed, #{servers => 5, quorum => {counting, 4, 2}})
        end),
        exercised(peace_dst:stats())
    end}.

%% Four servers in two rows: a row commits, one from each row elects.
faults_grid_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Row = fun(Is) -> [peace_dst:id(I) || I <- Is] end,
        sweep(lists:seq(1, 60), fun(Seed) ->
            opts(Seed, #{servers => 4, quorum => {grid, [Row([1, 2]), Row([3, 4])]}})
        end),
        exercised(peace_dst:stats())
    end}.

%% Leadership under attack: forced elections, two-server splits and late
%% `learned' messages, five servers. This is the workload that reaches the
%% stale-leader hazard; see the planted bug below.
churn_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 100), fun(Seed) -> opts(Seed, #{servers => 5, churn => true}) end),
        #{
            runs := Runs,
            acknowledged := Acked,
            leaderships := Leaderships,
            forced_elections := Elections,
            splits := Splits,
            rumours := Rumours
        } = Stats = peace_dst:stats(),
        ?assert(Acked >= Runs * 3, Stats),
        ?assert(Leaderships >= Runs * 3, Stats),
        ?assert(Elections >= Runs * 5, Stats),
        ?assert(Splits >= Runs * 3, Stats),
        ?assert(Rumours >= Runs * 5, Stats)
    end}.

%% The suite can fail. Quorums that do not intersect lose agreement, and the
%% failure shrinks to a trace that still reproduces it.
unsafe_quorums_are_caught_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Config = #{mode => unsafe_quorums},
        {Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) -> opts(Seed, Config) end),
        {violation, #{property := Property}} = maps:get(outcome, Result),
        ?assert(lists:member(Property, [agreement, acknowledged_is_decided, linearizable_read]), Property),
        Shrunk = eta_shrink:shrink(peace_dst, maps:get(trace, Result), opts(Seed, Config)),
        ?assertMatch(#{verified := true}, Shrunk, eta_run:summary(Shrunk))
    end}.

%% A server that forgets its promises across a restart is caught too.
amnesia_is_caught_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        {_Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) ->
            opts(Seed, #{mode => amnesia})
        end),
        ?assertMatch({violation, #{property := _}}, maps:get(outcome, Result))
    end}.

%% A deposed leader that learns a slot went against it and leads on gets a
%% follower to decide the value that lost. With the guard, the same seed is
%% clean.
stale_leader_is_caught_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Config = #{servers => 5, churn => true},
        Planted = Config#{mode => no_conflict_step_down},
        {Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) -> opts(Seed, Planted) end),
        ?assertMatch({violation, #{property := agreement}}, maps:get(outcome, Result)),
        Shrunk = eta_shrink:shrink(peace_dst, maps:get(trace, Result), opts(Seed, Planted)),
        ?assertMatch(#{verified := true}, Shrunk, eta_run:summary(Shrunk)),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, Config))), {seed, Seed})
    end}.

%% ---------------------------------------------------------------------------

sweep(Seeds, OptsFun) ->
    lists:foreach(
        fun(Seed) ->
            Result = run(OptsFun(Seed)),
            ?assertEqual(ok, maps:get(outcome, Result), {seed, Seed, eta_run:summary(Result)}),
            ?assertEqual(ok, eta_run:audit(Result), {seed, Seed, eta_run:summary(Result)})
        end,
        Seeds
    ).

first_violation([], _OptsFun) ->
    error(no_seed_found_the_planted_bug);
first_violation([Seed | Seeds], OptsFun) ->
    Result = run(OptsFun(Seed)),
    case maps:get(outcome, Result) of
        {violation, _} -> {Seed, Result};
        ok -> first_violation(Seeds, OptsFun);
        Other -> error({seed, Seed, Other, eta_run:summary(Result)})
    end.

%% The sweep did what it exists to do: clients were answered, the network
%% lost messages, servers were cut off, killed and brought back, and
%% leadership changed hands.
exercised(Stats) ->
    #{
        runs := Runs,
        acknowledged := Acked,
        queries_answered := Queries,
        leaderships := Leaderships,
        isolations := Isolations,
        crashes := Crashes,
        restarts := Restarts
    } = Stats,
    ?assert(Acked >= Runs * 3, Stats),
    ?assert(Queries >= Runs, Stats),
    ?assert(Leaderships > Runs, Stats),
    ?assert(Isolations >= Runs, Stats),
    ?assert(Crashes >= Runs, Stats),
    ?assert(Restarts >= Runs div 2, Stats).
