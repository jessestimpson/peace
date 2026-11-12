%% This module is the simulation suite. `make dst' runs the suite. `make dst'
%% is `rebar3 as dst eunit' on one scheduler thread. See the Makefile for the
%% reason.
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
        %% When no process is runnable, the run lets time pass more often
        %% than not. Elections and retransmissions happen only when timers
        %% on the clock fire.
        op_p => 0.15,
        quiet_p => 0.8,
        preload => [peace],
        net => #{policy => #{drop_p => 0.03, delay_p => 0.2, max_delay => 5}}
    }.

calm(Seed, Config) ->
    (opts(Seed, Config#{faults => false, converge => true}))#{net => true}.

run(Opts) ->
    eta_run:run(peace_dst, Opts).

%% A seed determines a run. The same seed produces the same trace every
%% time, and the recorded trace can be replayed.
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

%% This test runs with no faults. Every server ends with the same log, and
%% clients received answers.
calm_cluster_converges_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 20), fun(Seed) -> calm(Seed, #{}) end),
        #{acknowledged := Acked, runs := 20} = Stats = peace_dst:stats(),
        ?assert(Acked >= 20 * 40, Stats)
    end}.

%% This test runs with majority quorums and these faults: message loss,
%% message delay, isolation, crashes and restarts.
faults_majority_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 100), fun(Seed) -> opts(Seed, #{}) end),
        exercised(peace_dst:stats())
    end}.

%% This test runs the same faults with five servers. Two servers are needed
%% to commit and four servers are needed to elect.
faults_flexible_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 60), fun(Seed) ->
            opts(Seed, #{servers => 5, quorum => {counting, 4, 2}})
        end),
        exercised(peace_dst:stats())
    end}.

%% This test runs the same faults with four servers in a grid of two rows.
%% One row is needed to commit. One server from each row is needed to elect.
faults_grid_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Row = fun(Is) -> [peace_dst:id(I) || I <- Is] end,
        sweep(lists:seq(1, 60), fun(Seed) ->
            opts(Seed, #{servers => 4, quorum => {grid, [Row([1, 2]), Row([3, 4])]}})
        end),
        exercised(peace_dst:stats())
    end}.

%% This test runs the churn workload with five servers: forced elections,
%% two-server splits and late `learned' messages. The churn workload is the
%% workload that reaches the stale-leader hazard. See the planted bug in
%% `stale_leader_is_caught_test_' below.
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

%% This test changes membership during the run. Three of the five servers
%% are founders. Requests to change to other members and to other quorum
%% systems arrive among the values and the faults.
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

%% With `no_joint', a membership change goes directly to the new
%% configuration. The old configuration and the new configuration then
%% decide values separately from each other.
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

%% This test sends proposals to a phase-two quorum only (thesis section
%% 4.3.3), under every workload. The servers outside that quorum learn the
%% values by requesting them. All servers must still reach the same state.
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

%% This test runs read leases under both workloads. A leader answers a read
%% from the state of the leader whenever the leader holds a lease. The same
%% check applies to these reads as to reads that go through the log.
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
        %% Two servers in three have clocks that run six per cent fast. Six
        %% per cent is within the tenth that a lease allows for.
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, (long_lease())#{clock_drift => 6}) end),
        #{runs := Runs, queries_answered := Queries, leaderships := Leaderships} = Stats = peace_dst:stats(),
        ?assert(Queries >= Runs * 2, Stats),
        ?assert(Leaderships > Runs, Stats)
    end}.

long_lease() ->
    #{servers => 3, churn => true, read_lease_ms => 200, election_timeout_ms => 200}.

%% Without the lease fence, nothing guarantees the lease that a leader
%% assumes it holds. A read then returns a state that lacks acknowledged
%% values.
lease_fence_is_needed_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        %% The lease is long enough that a leader that is cut off receives a
        %% read before the lease expires.
        Config = long_lease(),
        {Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) ->
            opts(Seed, Config#{mode => no_lease_fence})
        end),
        ?assertMatch({violation, #{property := linearizable_read}}, maps:get(outcome, Result)),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, Config))), {seed, Seed})
    end}.

%% A lease assumes that all clocks run at nearly the same rate. In this
%% test the clocks of two servers in three run ten times fast. Those servers
%% stop being bound by a lease long before a leader with a true clock stops
%% relying on the lease, and a read returns stale state. This is not a bug
%% in peace. The test shows that the simulation detects a violation of the
%% clock assumption. About one seed in three hundred produces the violation,
%% so the search starts near a seed that produces the violation.
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

%% This test shows that the suite can fail. With quorums that do not
%% intersect, the servers do not keep agreement. The failing trace shrinks
%% to a trace that still reproduces the failure.
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

%% This test shows that the suite also detects a server that loses its
%% promises across a restart.
amnesia_is_caught_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        {_Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) ->
            opts(Seed, #{mode => amnesia})
        end),
        ?assertMatch({violation, #{property := _}}, maps:get(outcome, Result))
    end}.

%% This test runs the shipped dets backend under the same faults. Every
%% server that reopens its file recovers the state that the server wrote,
%% across kills, snapshots and truncation.
dets_backend_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        sweep(lists:seq(1, 60), fun(Seed) -> opts(Seed, #{disk => dets}) end),
        sweep(lists:seq(1, 30), fun(Seed) -> opts(Seed, #{disk => dets, servers => 5, quorum => {counting, 4, 2}}) end),
        Stats = #{snapshots := Snapshots} = peace_dst:stats(),
        exercised(Stats),
        ?assert(Snapshots > 0, Stats)
    end}.

%% This test shows that the check in `dets_backend_test_' can fail. The
%% test uses a backend that does not write promises.
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

%% A deposed leader learns that an index was decided with a value other than
%% the value that the leader proposed, and the leader continues to lead. The
%% leader then causes a follower to decide the value that was not decided.
%% With the guard, the same seed produces no violation.
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

%% A candidate becomes leader on a promise from a server that has dropped
%% indexes that the candidate never saw. The candidate then proposes its own
%% values at those indexes.
snapshot_guard_is_needed_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = peace_dst:reset_stats(),
        Config = #{mode => no_snapshot_guard},
        {Seed, Result} = first_violation(lists:seq(1, 300), fun(Seed) -> opts(Seed, Config) end),
        {violation, #{property := Property}} = maps:get(outcome, Result),
        ?assert(lists:member(Property, [agreement, applied_matches_decided, acknowledged_is_decided]), Property),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, #{}))), {seed, Seed})
    end}.

%% Clients that retry without a session cause values to be applied twice.
%% Without sessions, the clients of the suite would cause this in every run.
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

%% Asserts that the sweep exercised the behaviour that the sweep is meant to
%% exercise:
%%   - clients received acknowledgements of values and answers to queries;
%%   - leadership changed;
%%   - servers were cut off, killed and restarted;
%%   - servers took snapshots.
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
