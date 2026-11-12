%% A peace cluster under eta: the harness that starts it, drives it with
%% clients and faults, and judges it.
%%
%% == What runs ==
%%
%% `servers' (default 3) peace servers on one VM, each a `gen_server' the
%% scheduler steps and each on a simulated node of its own, with election and
%% heartbeat timers on the virtual clock and every message between them
%% through `eta_net', which the run's policy may drop or delay. Clients share
%% one more node. Their storage is `peace_dst_storage', an ETS table the
%% harness owns, so a killed server finds its promise and its log again when
%% it is restarted. That is the fault model `formal/FlexiblePaxos.tla'
%% assumes: messages are lost, duplicated in effect by retransmission, and
%% delayed; servers stop and come back with their durable state.
%%
%% == The workload ==
%%
%% Values and linearizable reads from clients, and when `faults' is on:
%% cutting a server off from the others, healing every cut, killing a
%% server, restarting one. A fault is an operation like any other, so it
%% lands where the seed put it, is recorded in the trace, and replays.
%%
%% == What is checked, after every step ==
%%
%% <ul>
%% <li>`storage_matches_memory' - what a server holds in memory as promised
%%   and accepted is what is on its disk. Since a step ends with the server
%%   back in its receive loop, having sent whatever it was going to send,
%%   this is "persist before you reply" observed from outside.</li>
%% <li>`promise_never_regresses' - a server's durable promise only grows.</li>
%% <li>`agreement' - no index is ever decided with two values, by anybody, at
%%   any time in the run. TLA+ `LearnedAgree'.</li>
%% <li>`applied_matches_decided' - a server's machine has applied exactly the
%%   decided log up to its commit index, in order, each session's value
%%   once. The decided log is the harness's own record, so this holds a
%%   server that was sent a snapshot to the same account as one that
%%   applied every entry.</li>
%% <li>`acknowledged_is_decided' - a client told `{ok, Index}' finds its
%%   value decided at that index.</li>
%% <li>`applied_once' - no machine has applied a value twice, however many
%%   indexes a client's retries put it in.</li>
%% <li>`linearizable_read' - a consistent query returns a prefix of the
%%   decided log that contains every value acknowledged before the query
%%   was issued.</li>
%% </ul>
%%
%% and at the end of a run with `converge' on: every server has applied the
%% same indexes to the same state and at least one value was acknowledged.
%%
%% Servers snapshot every few indexes, so that truncation, recovery from a
%% snapshot and catching up by one are part of every run. Clients submit
%% under a session and retry when they cannot tell what happened.
%%
%% == Membership ==
%%
%% With `reconfigure' on, the first three servers are the cluster and the
%% rest are running outside it, waiting to be told. One more operation asks
%% whoever leads to move to another configuration from a fixed list: other
%% members, more, fewer, none in common, another quorum system. Everything
%% above is checked as before, across every configuration the run passes
%% through, and convergence is asked of the members of the last one.
%%
%% == Disks and clocks ==
%%
%% `disk => dets' runs the shipped `peace_storage_dets' behind the
%% simulation's disk: see `peace_dst_storage'. `clock_drift => P' gives two
%% servers in three a clock P per cent fast, which matters only to read
%% leases; far enough beyond the tenth a lease allows for, a read is stale.
%%
%% == Trace validation ==
%%
%% `trace => Table' records every step of every server's core in the ETS
%% table `Table'. The caller creates the table and owns it, so the table
%% still exists after the run. Each server is given a `test_tracer' function
%% that appends one row per step: the step number, the server id, the event,
%% the durable state before and after, and the messages sent.
%% `peace_dst_trace' converts the rows into actions of
%% `formal/FlexiblePaxos.tla', and `peace_dst_trace_tests' runs TLC on them.
%%
%% == Planted bugs ==
%%
%% `mode' selects one, so that the suite can show each check is able to fail:
%%
%% <ul>
%% <li>`unsafe_quorums' - `{counting, 2, 1}' over three servers, with the
%%   server's own validation switched off. The same constants as
%%   `formal/FPaxosUnsafeQuorums.cfg'.</li>
%% <li>`amnesia' - a disk that comes back empty after a restart.</li>
%% <li>`lossy_disk' - with `disk => dets', the dets backend behind a layer
%%   that does not write promises. It shows `disk_recovers' can fail.</li>
%% <li>`no_snapshot_guard' - a candidate leads on a promise from an acceptor
%%   that has dropped indexes the candidate never learned. The same change as
%%   `formal/FPaxosNoSnapshotGuard.cfg'.</li>
%% <li>`no_joint' - a change of membership goes straight to the new
%%   configuration. The same change as `formal/ReconfigNoJoint.cfg'.</li>
%% <li>`no_lease_fence' - with read leases on, servers promise other epochs
%%   while a leader still counts on them, and a deposed leader answers a
%%   read from its own stale state.</li>
%% <li>`bare_retries' - clients retry without a session, and a value is
%%   applied twice. Not a bug in peace: it shows `applied_once' can fail.</li>
%% <li>`no_conflict_step_down' - a leader that learns an index was decided
%%   against its own proposal goes on leading. The same change as
%%   `formal/FPaxosNoConflictStepDown.cfg'.</li>
%% </ul>
%%
%% == Churn ==
%%
%% With `churn' on, the workload is aimed at leadership instead of at
%% durability, with three more operations in place of crashes:
%%
%% <ul>
%% <li>`{elect, I}' - a server is told its election timeout has fired when
%%   it has not. Any server may suspect its leader at any time.</li>
%% <li>`{split, I, J}' - two servers are cut off together from the rest, so
%%   that a leader can keep a follower while a new leader rises without
%%   either of them hearing of it.</li>
%% <li>`{rumour, I}' - a server receives `learned' for the latest indexes
%%   anybody has decided, through any cut. It stands for an answer to a
%%   catch-up request that was sent long ago and is only now arriving, and
%%   it is the TLA+ `CatchUp' action, which the model allows anybody at any
%%   time. The network policy alone almost never produces it: a leader
%%   only asks to catch up while it is still a follower.</li>
%% </ul>
%%
%% Together they reach the stale-leader hazard that `ConflictStepDown' in the
%% model guards against, which random loss and delay did not reach in
%% thousands of runs.
-module(peace_dst).

-behaviour(eta_harness).

-export([
    init/2,
    processes/1,
    generate/2,
    execute/2,
    check/1,
    check_final/2,
    settle_done/1,
    terminate/1
]).
-export([stats/0, reset_stats/0, id/1, bump/1]).

-define(STATS, peace_dst_stats).

%% ---------------------------------------------------------------------------
%% eta_harness
%% ---------------------------------------------------------------------------

init(_Seed, Config) ->
    N = maps:get(servers, Config, 3),
    Mode = maps:get(mode, Config, correct),
    %% dst/ is not part of the peace application, so `preload => [peace]'
    %% does not reach these, and a module loaded mid-run is a call to the
    %% code server that the schedule does not own.
    [{module, M} = code:ensure_loaded(M) || M <- [peace_dst_client, peace_dst_machine, peace_dst_storage, peace_dst_lossy_disk, peace_dst_trace]],
    %% Ordered, so that reading one server's disk is a range and not a scan.
    Tab = ets:new(peace_dst, [public, ordered_set]),
    Ids = [id(I) || I <- lists:seq(1, N)],
    Reconfigure = maps:get(reconfigure, Config, false),
    %% Who the cluster is to begin with. The others know it and wait.
    Founders =
        case Reconfigure of
            true -> lists:sublist(Ids, 3);
            false -> Ids
        end,
    Configs = maps:from_list([
        {I, server_config(I, lists:nth(I, Ids), Founders, Mode, Tab, Config)}
     || I <- lists:seq(1, N)
    ]),
    ok = clear_leftovers(N),
    ok = clear_disk(),
    Pids = [start(maps:get(I, Configs)) || I <- lists:seq(1, N)],
    ok = await_idle(Pids, 1000),
    %% Every process the run sends between is placed on a simulated node:
    %% one node per server, as deployed. Placement is what gives the faults
    %% their meaning. A cut is between nodes and so survives a restart, a
    %% kill takes everything on the node, and a restarted server inherits
    %% its node from the process that started it.
    lists:foreach(
        fun({I, Pid}) -> ok = eta_net:place(node_name(I), [Pid]) end,
        lists:zip(lists:seq(1, N), Pids)
    ),
    %% Connected at the start, as a cluster that has just booted is.
    [
        true = eta_net:with_node(node_name(I), fun() -> eta_net:connect_node(node_name(J)) end)
     || I <- lists:seq(1, N), J <- lists:seq(1, N), I < J
    ],
    {ok, #{
        tab => Tab,
        n => N,
        ids => Ids,
        configs => Configs,
        faults => maps:get(faults, Config, true),
        churn => maps:get(churn, Config, false),
        reconfigure => Reconfigure,
        retry =>
            case Mode of
                bare_retries -> bare;
                _ -> maps:get(retry, Config, session)
            end,
        converge => maps:get(converge, Config, false),
        %% Every client process ever spawned, oldest first.
        ops => [],
        %% Every restarter, oldest first. One stays alive for as long as the
        %% server it started, linked to it, as a supervisor would be.
        sups => [],
        clients => 0
    }}.

%% Servers by index, then operation processes by age. A restarted server is a
%% child of the operation that restarted it and is adopted with it; listing
%% it here as well is harmless and keeps the order a function of the run.
processes(#{n := N, ops := Ops, sups := Sups}) ->
    [Pid || I <- lists:seq(1, N), Pid <- [server_pid(I)], is_pid(Pid)] ++
        [Pid || Pid <- Ops ++ Sups, is_process_alive(Pid)].

generate(S = #{reconfigure := true}, Rand0) ->
    %% One draw more than a run without, and only here, so that turning
    %% this on does not change what every other seed means.
    {Roll, Rand1} = rand:uniform_s(Rand0),
    case Roll < 0.07 of
        true ->
            {K, Rand2} = rand:uniform_s(length(targets(S)), Rand1),
            {{reconfigure, K}, Rand2};
        false ->
            generate1(S, Rand1)
    end;
generate(S, Rand) ->
    generate1(S, Rand).

generate1(#{n := N, faults := Faults, churn := Churn}, Rand0) ->
    {Roll, Rand1} = rand:uniform_s(Rand0),
    {I, Rand2} = rand:uniform_s(N, Rand1),
    Op =
        if
            Churn, Roll < 0.45 -> {value, I};
            Churn, Roll < 0.53 -> {query, I};
            Churn, Roll < 0.68 -> {elect, I};
            Churn, Roll < 0.76 -> {split, I, I rem N + 1};
            Churn, Roll < 0.90 -> {rumour, I};
            Churn, Roll < 0.94 -> {isolate, I};
            Churn -> heal;
            not Faults, Roll < 0.80 -> {value, I};
            not Faults -> {query, I};
            %% Faults are kept rare. Too many and no value ever completes,
            %% and only a completed value can contradict anything.
            Roll < 0.62 -> {value, I};
            Roll < 0.80 -> {query, I};
            Roll < 0.84 -> {isolate, I};
            Roll < 0.91 -> heal;
            Roll < 0.94 -> {crash, I};
            true -> {restart, I}
        end,
    {Op, Rand2}.

%% Client operations name the server they try first by index, and the
%% operation's own identity is its position in the run: nothing in an
%% operation is a pid, a ref or a generated name, so a trace replays.
execute({value, First}, S = #{tab := Tab, ids := Ids, clients := C0}) ->
    C = C0 + 1,
    Servers = rotate(First, Ids),
    Retry = maps:get(retry, S),
    spawn_op(clients, fun() -> peace_dst_client:value(Tab, C, Servers, C, Retry) end, S#{clients := C});
execute({query, First}, S = #{tab := Tab, ids := Ids, clients := C0}) ->
    C = C0 + 1,
    Servers = rotate(First, Ids),
    spawn_op(clients, fun() -> peace_dst_client:query(Tab, C, Servers) end, S#{clients := C});
%% A message fault, not a node failure: both ends go on believing the link is
%% up, which is all peace can tell anyway, since it detects failure by
%% silence and not by `nodedown'.
execute({isolate, I}, S = #{n := N}) ->
    lists:foreach(
        fun(J) ->
            ok = eta_net:cut(node_name(I), node_name(J)),
            ok = eta_net:cut(node_name(J), node_name(I))
        end,
        lists:seq(1, N) -- [I]
    ),
    bump(isolations),
    S;
execute(heal, S) ->
    ok = eta_net:heal_all(),
    S;
execute({crash, I}, S) ->
    case server_pid(I) of
        undefined ->
            S;
        _Pid ->
            %% Everything on the node dies at once, between steps, and is
            %% waited for. Its disk is the harness's and stays.
            ok = eta_net:kill_node(node_name(I)),
            bump(crashes),
            S
    end;
execute({elect, I}, S = #{ids := Ids}) ->
    bump(forced_elections),
    Id = lists:nth(I, Ids),
    spawn_op(node_name(I), fun() -> peace:trigger_election(Id) end, S);
execute({reconfigure, K}, S = #{tab := Tab, ids := Ids, clients := C0}) ->
    C = C0 + 1,
    {Members, Quorum} = lists:nth(K, targets(S)),
    Servers = rotate((K rem length(Ids)) + 1, Ids),
    spawn_op(
        clients,
        fun() -> peace_dst_client:reconfigure(Tab, C, Servers, Members, Quorum) end,
        S#{clients := C}
    );
execute({split, I, J}, S = #{n := N}) ->
    Others = lists:seq(1, N) -- [I, J],
    lists:foreach(
        fun({A, B}) ->
            ok = eta_net:cut(node_name(A), node_name(B)),
            ok = eta_net:cut(node_name(B), node_name(A))
        end,
        [{A, B} || A <- [I, J], B <- Others]
    ),
    bump(splits),
    S;
execute({rumour, I}, S = #{tab := Tab, ids := Ids, n := N}) ->
    Decided = lists:sort([{Index, Value} || [Index, Value] <- ets:match(Tab, {{decided, '$1'}, '$2'})]),
    case lists:nthtail(max(0, length(Decided) - 4), Decided) of
        [] ->
            S;
        Latest ->
            bump(rumours),
            To = lists:nth(I, Ids),
            From = lists:nth(I rem N + 1, Ids),
            %% Sent from the receiver's own node: it was in flight before
            %% whatever cut there is now.
            spawn_op(node_name(I), fun() -> peace_dst_client:deliver(To, From, {learned, Latest}) end, S)
    end;
execute({restart, I}, S = #{configs := Configs}) ->
    case server_pid(I) of
        undefined ->
            Config = maps:get(I, Configs),
            bump(restarts),
            %% The server is the restarter's child and inherits its node.
            Pid = eta_run:spawn_op(fun() -> peace_dst_client:restart(Config) end),
            ok = eta_net:place(node_name(I), [Pid]),
            S#{sups := maps:get(sups, S) ++ [Pid]};
        _Running ->
            S
    end.

check(#{tab := Tab, ids := Ids}) ->
    Views = [{Id, view(Id)} || Id <- Ids],
    Disks = [{Id, stored_promised(Tab, Id), peace_dst_storage:entries(Tab, Id)} || Id <- Ids],
    Record = decided_record(Tab),
    ok = note_leaders(Views),
    first_violation([
        fun() -> disk_recovers(Tab) end,
        fun() -> storage_matches_memory(Tab, Views, Disks) end,
        fun() -> promise_never_regresses(Tab, Disks) end,
        fun() -> agreement(Tab, Disks) end,
        fun() -> applied_matches_decided(Views, Record) end,
        fun() -> acknowledged_is_decided(Tab) end,
        fun() -> applied_once(Views) end,
        fun() -> linearizable_read(Tab, Record) end
    ]).

check_final(_Settled, #{converge := false}) ->
    ok;
check_final(Settled, #{tab := Tab, ids := Ids, converge := true}) ->
    Logs = [{Id, applied(Core)} || {Id, Core} <- current_members(Ids)],
    Acked = [Op || [Op] <- ets:match(Tab, {{op, '$1'}, {ok, '_'}})],
    case lists:usort([Log || {_Id, Log} <- Logs]) of
        [_One] when Acked =/= [] ->
            ok;
        [_One] ->
            violation(nothing_acknowledged, #{settled => Settled});
        _Several ->
            violation(converged, #{settled => Settled, decided => Logs})
    end.

%% The workload is over once every client has its answer. A cluster with a
%% heartbeat never goes quiet, so without this every run would spend its
%% whole settle budget watching heartbeats. When convergence is going to be
%% asserted, wait for it.
settle_done(#{ops := Ops, converge := Converge, ids := Ids}) ->
    not lists:any(fun is_process_alive/1, Ops) andalso
        (not Converge orelse
            case lists:usort([applied(Core) || {_Id, Core} <- current_members(Ids)]) of
                [_One] -> true;
                _ -> false
            end).

terminate(S = #{tab := Tab, n := N}) ->
    ok = record_stats(Tab),
    %% Restarters first: a server one of them has started but that has not
    %% registered its name yet can only be reached through the link.
    ok = kill(maps:get(sups, S)),
    ok = kill(maps:get(ops, S) ++ [Pid || I <- lists:seq(1, N), Pid <- [server_pid(I)], is_pid(Pid)]),
    ok = await_unregistered(N, 1000),
    catch ets:delete(Tab),
    ok = clear_disk(),
    ok.

%% Where `disk => dets' keeps its files. One place, emptied before and after
%% each run, so that a run's name for it does not differ from the last one's.
disk_dir() ->
    filename:join(filename:basedir(user_cache, "peace_dst"), "disk").

%% With `prim_file': the file server is a process no schedule owns.
clear_disk() ->
    Dir = disk_dir(),
    case prim_file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> ok = prim_file:delete(filename:join(Dir, Name)) end, Names);
        {error, enoent} ->
            ok
    end.

%% Kills and waits, so that nothing from this run is still dying into the next.
kill(Pids) ->
    Refs = [{Pid, erlang:monitor(process, Pid)} || Pid <- Pids],
    lists:foreach(fun({Pid, _Ref}) -> exit(Pid, kill) end, Refs),
    lists:foreach(
        fun({Pid, Ref}) ->
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            end
        end,
        Refs
    ).

%% ---------------------------------------------------------------------------
%% Invariants
%% ---------------------------------------------------------------------------

%% With `disk => dets': a server that opened its dets file found what it had
%% written, which is to say what the simulation's own disk holds.
disk_recovers(Tab) ->
    case ets:match(Tab, {{disk_differs, '$1'}, '$2', '$3'}) of
        [] -> ok;
        Differ -> violation(disk_recovers, #{servers => [{Id, #{dets => D, wrote => W}} || [Id, D, W] <- Differ]})
    end.

storage_matches_memory(Tab, Views, Disks) ->
    Wrong = [
        {Id, #{
            promised => {peace_core:promised(Core), Promised},
            snapshot => {peace_core:snapshot_index(Core), peace_dst_storage:snapshot_index(Tab, Id)},
            only_in_memory => maps:without(maps:keys(Stored), Log),
            only_on_disk => maps:without(maps:keys(Log), Stored),
            differ => [I || {I, E} <- maps:to_list(Log), maps:get(I, Stored, E) =/= E]
        }}
     || {{Id, {live, Core}}, {Id, Promised, Stored}} <- lists:zip(Views, Disks),
        Log <- [peace_core:log(Core)],
        peace_core:promised(Core) =/= Promised orelse Log =/= Stored orelse
            peace_core:snapshot_index(Core) =/= peace_dst_storage:snapshot_index(Tab, Id)
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(storage_matches_memory, #{servers => Wrong})
    end.

promise_never_regresses(Tab, Disks) ->
    Regressed = [
        {Id, #{was => Was, now => Now}}
     || {Id, Now, _Stored} <- Disks,
        Was <- [ets:lookup_element(Tab, {high_promise, Id}, 2, Now)],
        true = ets:insert(Tab, {{high_promise, Id}, max(Was, Now)}),
        Now < Was
    ],
    case Regressed of
        [] -> ok;
        _ -> violation(promise_never_regresses, #{servers => Regressed})
    end.

%% Read from the disks, not from the servers, so that a server that decided
%% something and was then killed still counts. Each index's value is
%% remembered the first time anybody decides it and compared ever after.
agreement(Tab, Disks) ->
    Conflicts =
        [
            #{index => I, server => Id, decided => Value, earlier => Earlier}
         || {Id, _Promised, Stored} <- Disks,
            {I, {learned, Value}} <- lists:sort(maps:to_list(Stored)),
            Earlier <- [remembered(Tab, {decided, I}, Value)],
            Earlier =/= Value
        ] ++
            %% Noted by the disk at the write: see `peace_dst_storage'.
            [
                #{index => I, server => Id, decided => Value, earlier => Earlier}
             || [I, Id, Value, Earlier] <- ets:match(Tab, {{conflict, '$1', '$2'}, '$3', '$4'})
            ],
    case Conflicts of
        [] -> ok;
        _ -> violation(agreement, #{conflicts => Conflicts})
    end.

applied_matches_decided(Views, Record) ->
    Wrong = [
        {Id, #{commit => Commit, applied => Applied, decided => Expected}}
     || {Id, {live, Core}} <- Views,
        Commit <- [peace_core:commit_index(Core)],
        Applied <- [lists:reverse(peace_core:machine_state(Core))],
        Expected <- [expected(Commit, Record)],
        Applied =/= Expected
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(applied_matches_decided, #{servers => Wrong})
    end.

%% What a machine holds after the first `Commit' indexes of the decided log:
%% every value without a session, and each session's value the first
%% time it appears. `missing' if the record does not reach that far, which
%% no server's commit index may run ahead of.
expected(Commit, Record) ->
    expected(1, Commit, Record, #{}, []).

expected(I, Commit, _Record, _Sessions, Acc) when I > Commit ->
    lists:reverse(Acc);
expected(I, Commit, Record, Sessions, Acc) ->
    case Record of
        #{I := {'$usr', _Tag, Value}} ->
            expected(I + 1, Commit, Record, Sessions, [{I, Value} | Acc]);
        #{I := {'$ses', _Tag, {Client, Seq}, Value}} ->
            case Sessions of
                #{Client := Last} when Last >= Seq ->
                    expected(I + 1, Commit, Record, Sessions, Acc);
                _ ->
                    expected(I + 1, Commit, Record, Sessions#{Client => Seq}, [{I, Value} | Acc])
            end;
        #{I := {'$noop', _Tag}} ->
            expected(I + 1, Commit, Record, Sessions, Acc);
        #{I := {'$cfg', _Tag, _Cfg}} ->
            expected(I + 1, Commit, Record, Sessions, Acc);
        _ ->
            {missing, I}
    end.

decided_record(Tab) ->
    maps:from_list([{I, Value} || [I, Value] <- ets:match(Tab, {{decided, '$1'}, '$2'})]).

%% The live members of the latest configuration anybody has: the one in
%% force at whoever has applied most. A server that was removed stops being
%% told anything and is not expected to keep up.
current_members(Ids) ->
    Live = [{Id, Core} || Id <- Ids, {live, Core} <- [view(Id)]],
    case lists:sort([{peace_core:commit_index(Core), Id} || {Id, Core} <- Live]) of
        [] ->
            [];
        Sorted ->
            {_Commit, Furthest} = lists:last(Sorted),
            Members = peace_core:members(proplists:get_value(Furthest, Live)),
            [{Id, Core} || {Id, Core} <- Live, lists:member(Id, Members)]
    end.

%% The configurations a run moves between. Over five servers: back to the
%% founders, a set that shares one server with them, everybody with two to
%% commit, a pair with nothing in common with the founders, and four.
targets(#{ids := Ids}) ->
    Pick = fun(Is) -> [lists:nth(I, Ids) || I <- Is, I =< length(Ids)] end,
    [
        {Pick([1, 2, 3]), majority},
        {Pick([3, 4, 5]), majority},
        {Pick([1, 2, 3, 4, 5]), {counting, 4, 2}},
        {Pick([4, 5]), majority},
        {Pick([1, 2, 4, 5]), {counting, 3, 2}}
    ].

%% What is compared between servers at the end: how far each has applied,
%% and to what.
applied(Core) ->
    {peace_core:commit_index(Core), peace_core:machine_state(Core)}.

acknowledged_is_decided(Tab) ->
    Wrong = [
        #{op => Op, told => Index, decided => At}
     || [Op, Index] <- ets:match(Tab, {{op, '$1'}, {ok, '$2'}}),
        At <- [decided_at(Tab, Index)],
        At =/= {put, Op}
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(acknowledged_is_decided, #{values => Wrong})
    end.

applied_once(Views) ->
    Twice = [
        {Id, lists:usort(Ops -- lists:usort(Ops))}
     || {Id, {live, Core}} <- Views,
        Ops <- [[Op || {_I, {put, Op}} <- peace_core:machine_state(Core)]],
        length(Ops) =/= length(lists:usort(Ops))
    ],
    case Twice of
        [] -> ok;
        _ -> violation(applied_once, #{servers => Twice})
    end.

linearizable_read(Tab, Record) ->
    Wrong = [
        #{query => N, missing => Before -- Saw, saw => Saw}
     || [N, Before, Saw] <- ets:match(Tab, {{query, '$1'}, '$2', {ok, '$3'}}),
        Before -- Saw =/= [] orelse not is_applied_prefix(Record, lists:reverse(Saw))
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(linearizable_read, #{queries => Wrong})
    end.

%% Whether `Ops', oldest first, is what a machine holds after some prefix of
%% the decided log.
is_applied_prefix(Record, Ops) ->
    Last = lists:max([0 | maps:keys(Record)]),
    lists:any(
        fun(Commit) ->
            case expected(Commit, Record) of
                {missing, _} -> false;
                Applied -> [Op || {_I, {put, Op}} <- Applied] =:= Ops
            end
        end,
        lists:seq(0, Last)
    ).

decided_at(Tab, Index) ->
    case ets:lookup(Tab, {decided, Index}) of
        [{_, {'$usr', _Tag, Value}}] -> Value;
        [{_, {'$ses', _Tag, _Session, Value}}] -> Value;
        [{_, {'$noop', _Tag}}] -> noop;
        [{_, {'$cfg', _Tag, _Cfg}}] -> cfg;
        [] -> undecided
    end.

first_violation([]) ->
    ok;
first_violation([Check | Rest]) ->
    case Check() of
        ok -> first_violation(Rest);
        Violation -> Violation
    end.

%% A `property' key is what `eta_shrink' uses to tell one failure from another.
violation(Property, Detail) ->
    {violation, Detail#{property => Property}}.

%% The value first stored under `Key', storing `Value' if there is none.
remembered(Tab, Key, Value) ->
    case ets:insert_new(Tab, {Key, Value}) of
        true -> Value;
        false -> ets:lookup_element(Tab, Key, 2)
    end.

stored_promised(Tab, Id) ->
    case peace_dst_storage:promised(Tab, Id) of
        undefined -> {0, none};
        Epoch -> Epoch
    end.

%% ---------------------------------------------------------------------------
%% The cluster
%% ---------------------------------------------------------------------------

server_config(I, Id, Founders, Mode, Tab, Config) ->
    Server = server_config1(I, Id, Founders, Mode, Tab, Config),
    case Config of
        %% Every step every server takes, in the order they were taken, for
        %% `peace_dst_trace' to hold against the model. The table is the
        %% caller's, so it outlives the run.
        #{trace := Trace} ->
            Server#{
                test_tracer => fun({_, Event, Before, After, Effects}) ->
                    N = ets:update_counter(Trace, seq, 1, {seq, 0}),
                    ets:insert(
                        Trace,
                        {N, Id, peace_dst_trace:event(Event), peace_dst_trace:view(Before),
                            peace_dst_trace:view(After), peace_dst_trace:sends(Effects)}
                    )
                end
            };
        _ ->
            Server
    end.

server_config1(I, Id, Founders, Mode, Tab, Config) ->
    Storage =
        case {maps:get(disk, Config, model), Mode} of
            {model, _} -> #{tab => Tab};
            {dets, lossy_disk} ->
                #{tab => Tab, node => node_name(I), disk => {peace_dst_lossy_disk, #{dir => disk_dir()}}};
            {dets, _} ->
                #{tab => Tab, node => node_name(I), disk => {peace_storage_dets, #{dir => disk_dir()}}}
        end,
    Base = #{
        id => Id,
        members => Founders,
        machine => {module, peace_dst_machine, []},
        quorum => maps:get(quorum, Config, majority),
        storage => {peace_dst_storage, Storage},
        %% Short against the pace of the workload. A run injects its
        %% operations within a few virtual seconds, so an election that took
        %% one of them would leave most clients with nobody to talk to.
        election_timeout_ms => maps:get(election_timeout_ms, Config, 50),
        heartbeat_ms => 10,
        %% Often enough that every run truncates, restarts from a snapshot
        %% and sends one.
        snapshot_interval => maps:get(snapshot_interval, Config, 5)
    },
    Leased0 = maps:merge(Base, maps:with([read_lease_ms, propose_to], Config)),
    %% Clocks that run at different rates: every third server's is true and
    %% the others run fast by `clock_drift' per cent, so that they count a
    %% lease out sooner than a true leader does. (A slow server is no
    %% threat: it stays bound, and so out of elections, for longer.) The
    %% simulation's own clock is the true one, and timers run on it.
    Leased =
        case {maps:get(clock_drift, Config, 0), I rem 3} of
            {0, _} -> Leased0;
            {_, 0} -> Leased0;
            {Drift, _} -> Leased0#{test_clock_rate => {100 + Drift, 100}}
        end,
    case Mode of
        correct ->
            Leased;
        no_lease_fence ->
            Leased#{unsafe_no_lease_fence => true};
        no_joint ->
            Leased#{unsafe_no_joint => true};
        unsafe_quorums ->
            Base#{quorum => {counting, 2, 1}, unsafe_no_quorum_check => true};
        no_conflict_step_down ->
            Base#{unsafe_no_conflict_step_down => true};
        no_snapshot_guard ->
            Base#{unsafe_no_snapshot_guard => true};
        bare_retries ->
            Base;
        lossy_disk ->
            Base;
        amnesia ->
            Base#{storage => {peace_dst_storage, #{tab => Tab, amnesia => true}}}
    end.

%% Before the scheduler exists, so this is an ordinary start on the real
%% scheduler. The clock is already virtual: the election timer armed in
%% `init/1' is the first thing the run will advance to.
start(Config) ->
    {ok, Pid} = peace_server:start(Config),
    Pid.

%% A server that was mid-start when the previous run was torn down dies with
%% its restarter, but may have registered its name on the way out.
clear_leftovers(N) ->
    ok = kill([Pid || I <- lists:seq(1, N), Pid <- [whereis(name(I))], is_pid(Pid)]),
    await_unregistered(N, 1000).

%% The system is handed over idle: every server in its receive loop with
%% nothing queued, so nothing that happened on the real scheduler is left to
%% land at a point the seed did not choose.
await_idle(_Pids, 0) ->
    error(servers_not_idle);
await_idle(Pids, Attempts) ->
    Busy = [
        Pid
     || Pid <- Pids,
        {status, Status} <- [process_info(Pid, status)],
        {message_queue_len, Len} <- [process_info(Pid, message_queue_len)],
        Status =/= waiting orelse Len > 0
    ],
    case Busy of
        [] ->
            ok;
        _ ->
            timer:sleep(1),
            await_idle(Pids, Attempts - 1)
    end.

await_unregistered(_N, 0) ->
    error(servers_not_stopped);
await_unregistered(N, Attempts) ->
    case [I || I <- lists:seq(1, N), server_pid(I) =/= undefined] of
        [] ->
            ok;
        _ ->
            timer:sleep(1),
            await_unregistered(N, Attempts - 1)
    end.

%% The new process is blocked until the scheduler adopts it, so it is on its
%% node before it has run a line.
spawn_op(Node, Fun, S = #{ops := Ops}) ->
    Pid = eta_run:spawn_op(Fun),
    ok = eta_net:place(Node, [Pid]),
    S#{ops := Ops ++ [Pid]}.

%% A server's protocol state, read without asking it.
view({Name, Node}) ->
    case server_pid(Name, Node) of
        undefined ->
            down;
        Pid ->
            case eta_observe:read(Pid) of
                #{core := Core} -> {live, Core};
                _ -> starting
            end
    end.

id(I) -> {name(I), node_name(I)}.

name(I) -> list_to_atom("peace_dst_" ++ integer_to_list(I)).

node_name(I) -> list_to_atom("peace_n" ++ integer_to_list(I)).

server_pid(I) ->
    server_pid(name(I), node_name(I)).

%% A server started in `init/2' registered its name before it was placed, in
%% the VM's own namespace. One restarted during the run was born on its node
%% and registered in that node's.
server_pid(Name, Node) ->
    case whereis(Name) of
        undefined ->
            case whereis(eta_ns:name(Node, Name)) of
                undefined -> undefined;
                Pid -> Pid
            end;
        Pid ->
            Pid
    end.

rotate(First, Ids) ->
    {Front, Back} = lists:split(First - 1, Ids),
    Back ++ Front.

%% ---------------------------------------------------------------------------
%% Statistics: did the run exercise what it was meant to?
%%
%% A sweep that passes because no client was ever answered, or no leader ever
%% changed, has checked nothing. The suite owns a table, the harness adds a
%% run's counts to it, and the suite asserts on the totals.
%% ---------------------------------------------------------------------------

reset_stats() ->
    catch ets:delete(?STATS),
    ?STATS = ets:new(?STATS, [named_table, public, set]),
    ok.

stats() ->
    maps:from_list(ets:tab2list(?STATS)).

bump(Key) ->
    bump(Key, 1).

bump(Key, By) ->
    case ets:whereis(?STATS) of
        undefined -> ok;
        _ -> _ = ets:update_counter(?STATS, Key, By, {Key, 0})
    end,
    ok.

%% Epochs somebody led with. More than one in a run means leadership moved.
note_leaders(Views) ->
    lists:foreach(
        fun
            ({Id, {live, Core}}) ->
                case peace_core:role(Core) of
                    leader -> noted({led, peace_core:promised(Core), Id});
                    _ -> ok
                end;
            (_) ->
                ok
        end,
        Views
    ).

noted(Key) ->
    case ets:whereis(?STATS) of
        undefined ->
            ok;
        _ ->
            case ets:insert_new(?STATS, {Key, true}) of
                true -> bump(leaderships);
                false -> ok
            end
    end.

record_stats(Tab) ->
    Results = [Result || [Result] <- ets:match(Tab, {{op, '_'}, '$1'})],
    bump(runs),
    bump(acknowledged, length([ok || {ok, _} <- Results])),
    bump(rejected, length([ok || {rejected, _} <- Results])),
    bump(unknown, length([ok || {unknown, _} <- Results])),
    bump(queries_answered, length(ets:match(Tab, {{query, '_'}, '_', {ok, '_'}}))),
    bump(indexes_decided, length(ets:match(Tab, {{decided, '_'}, '_'}))),
    bump(reconfigured, length(ets:match(Tab, {{reconfigure, '_'}, {ok, '_'}}))),
    bump(
        configurations,
        length([ok || [{'$cfg', _Tag, {final, _}}] <- ets:match(Tab, {{decided, '_'}, '$1'})])
    ),
    catch ets:match_delete(?STATS, {{led, '_', '_'}, '_'}),
    ok.
