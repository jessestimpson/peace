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

%% Membership changing under the run: three founders out of five servers,
%% and requests to move to other members and other quorum systems arriving
%% among the values and the faults.
membership_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 20), fun(Seed) ->
            calm(Seed, #{servers => 5, reconfigure => true})
        end),
        sweep(lists:seq(1, 80), fun(Seed) -> opts(Seed, #{servers => 5, reconfigure => true}) end),
        sweep(lists:seq(1, 80), fun(Seed) ->
            opts(Seed, #{servers => 5, reconfigure => true, churn => true})
        end),
        sweep(lists:seq(1, 40), fun(Seed) ->
            opts(Seed, #{servers => 5, reconfigure => true, churn => true, read_lease_ms => 40})
        end),
        #{runs := Runs, acknowledged := Acked, reconfigured := Told, configurations := Changes} =
            Stats = peace_dst:stats(),
        ?assert(Acked >= Runs * 3, Stats),
        ?assert(Told >= Runs, Stats),
        ?assert(Changes >= Runs, Stats)
    end}.

%% Straight to the new configuration, and the old and the new decide apart.
joint_configuration_is_needed_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Config = #{servers => 5, reconfigure => true, churn => true},
        {Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) ->
            opts(Seed, Config#{mode => no_joint})
        end),
        {violation, #{property := Property}} = maps:get(outcome, Result),
        ?assert(lists:member(Property, [agreement, applied_matches_decided, acknowledged_is_decided]), Property),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, Config))), {seed, Seed})
    end}.

%% Proposals sent to a phase-two quorum and no further (thesis section
%% 4.3.3), under every workload:
%% the servers left out learn by asking, and still have to end up the same.
propose_to_quorum_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Flexible = #{servers => 5, quorum => {counting, 4, 2}, propose_to => quorum},
        Row = fun(Is) -> [peace_dst:id(I) || I <- Is] end,
        sweep(lists:seq(1, 20), fun(Seed) -> calm(Seed, Flexible) end),
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, Flexible) end),
        sweep(lists:seq(1, 40), fun(Seed) ->
            opts(Seed, #{servers => 4, quorum => {grid, [Row([1, 2]), Row([3, 4])]}, propose_to => quorum})
        end),
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, #{servers => 5, churn => true, propose_to => quorum}) end),
        sweep(lists:seq(1, 40), fun(Seed) ->
            opts(Seed, #{servers => 5, reconfigure => true, propose_to => quorum, read_lease_ms => 40})
        end),
        #{runs := Runs, acknowledged := Acked, leaderships := Leaderships} = Stats = peace_dst:stats(),
        ?assert(Acked >= Runs * 3, Stats),
        ?assert(Leaderships > Runs, Stats)
    end}.

%% Read leases, under both workloads. Reads are answered from the leader's
%% state whenever it holds a lease, and are held to the same check as reads
%% that go through the log.
leases_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, #{read_lease_ms => 40}) end),
        sweep(lists:seq(1, 60), fun(Seed) ->
            opts(Seed, #{servers => 5, churn => true, read_lease_ms => 40})
        end),
        sweep(lists:seq(1, 40), fun(Seed) ->
            opts(Seed, #{servers => 5, quorum => {counting, 4, 2}, churn => true, read_lease_ms => 40})
        end),
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, long_lease()) end),
        %% Two servers in three with clocks six per cent fast: inside the
        %% tenth a lease allows for.
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, (long_lease())#{clock_drift => 6}) end),
        #{runs := Runs, queries_answered := Queries, leaderships := Leaderships} = Stats = peace_dst:stats(),
        ?assert(Queries >= Runs * 2, Stats),
        ?assert(Leaderships > Runs, Stats)
    end}.

long_lease() ->
    #{servers => 3, churn => true, read_lease_ms => 200, election_timeout_ms => 200}.

%% Without the fence a lease is a leader's unfounded belief, and a read sees
%% a state that is missing acknowledged values.
lease_fence_is_needed_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        %% A lease long enough for a cut-off leader to be asked something
        %% before it expires.
        Config = long_lease(),
        {Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) ->
            opts(Seed, Config#{mode => no_lease_fence})
        end),
        ?assertMatch({violation, #{property := linearizable_read}}, maps:get(outcome, Result)),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, Config))), {seed, Seed})
    end}.

%% A lease assumes clocks that run at nearly one rate. With two servers in
%% three running ten times fast they are free of a lease long before a true
%% leader stops counting on it, and a read is stale. Not a bug in peace: it
%% shows the simulation can tell when the assumption is broken. About one
%% seed in three hundred finds it, so the search starts near one that does.
lease_needs_clocks_that_agree_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Config = long_lease(),
        {Seed, Result} = first_violation(lists:seq(500, 1300), fun(Seed) ->
            opts(Seed, Config#{clock_drift => 900})
        end),
        ?assertMatch({violation, #{property := linearizable_read}}, maps:get(outcome, Result)),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, Config#{clock_drift => 6}))), {seed, Seed})
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

%% The shipped dets backend under the same faults: every server that reopens
%% its file finds what it wrote, across kills, snapshots and truncation.
dets_backend_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, #{disk => dets}) end),
        sweep(lists:seq(1, 30), fun(Seed) -> opts(Seed, #{disk => dets, servers => 5, quorum => {counting, 4, 2}}) end),
        Stats = #{snapshots := Snapshots} = peace_dst:stats(),
        exercised(Stats),
        ?assert(Snapshots > 0, Stats)
    end}.

%% And that check can fail: a backend that does not write promises.
lossy_disk_is_caught_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Config = #{disk => dets},
        {Seed, Result} = first_violation(lists:seq(1, 100), fun(Seed) ->
            opts(Seed, Config#{mode => lossy_disk})
        end),
        ?assertMatch({violation, #{property := disk_recovers}}, maps:get(outcome, Result)),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, Config))), {seed, Seed})
    end}.

%% A deposed leader that learns an index went against it and leads on gets a
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

%% A candidate that leads on a promise from a server that has dropped indexes
%% the candidate never saw puts its own values in them.
snapshot_guard_is_needed_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Config = #{mode => no_snapshot_guard},
        {Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) -> opts(Seed, Config) end),
        {violation, #{property := Property}} = maps:get(outcome, Result),
        ?assert(lists:member(Property, [agreement, applied_matches_decided, acknowledged_is_decided]), Property),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, #{}))), {seed, Seed})
    end}.

%% Clients that retry without a session get values applied twice, which
%% is what the suite's clients would be doing to every run without them.
bare_retries_apply_twice_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        {_Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) ->
            opts(Seed, #{mode => bare_retries})
        end),
        ?assertMatch({violation, #{property := applied_once}}, maps:get(outcome, Result))
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
    ?assert(Restarts >= Runs div 2, Stats),
    ?assert(maps:get(snapshots, Stats, 0) >= Runs * 3, Stats).
