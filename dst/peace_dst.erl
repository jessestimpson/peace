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
%% Commands and linearizable reads from clients, and when `faults' is on:
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
%% <li>`agreement' - no slot is ever decided with two values, by anybody, at
%%   any time in the run. TLA+ `DecidedAgree'.</li>
%% <li>`applied_matches_decided' - a server's machine has applied exactly its
%%   decided prefix, in order.</li>
%% <li>`acknowledged_is_decided' - a client told `{ok, Index}' finds its
%%   command decided at that slot.</li>
%% <li>`decided_once' - no command occupies two slots.</li>
%% <li>`linearizable_read' - a consistent query returns a prefix of the
%%   decided log that contains every command acknowledged before the query
%%   was issued.</li>
%% </ul>
%%
%% and at the end of a run with `converge' on: every server has the same
%% decided log and at least one command was acknowledged.
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
%% </ul>
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
-export([stats/0, reset_stats/0, id/1]).

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
    [{module, M} = code:ensure_loaded(M) || M <- [peace_dst_client, peace_dst_machine, peace_dst_storage]],
    %% Ordered, so that reading one server's disk is a range and not a scan.
    Tab = ets:new(peace_dst, [public, ordered_set]),
    Ids = [id(I) || I <- lists:seq(1, N)],
    Configs = maps:from_list([{I, server_config(I, Ids, Mode, Tab, Config)} || I <- lists:seq(1, N)]),
    ok = clear_leftovers(N),
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

generate(#{n := N, faults := Faults}, Rand0) ->
    {Roll, Rand1} = rand:uniform_s(Rand0),
    {I, Rand2} = rand:uniform_s(N, Rand1),
    Op =
        if
            not Faults, Roll < 0.80 -> {command, I};
            not Faults -> {query, I};
            %% Faults are kept rare. Too many and no command ever completes,
            %% and only a completed command can contradict anything.
            Roll < 0.62 -> {command, I};
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
execute({command, First}, S = #{tab := Tab, ids := Ids, clients := C0}) ->
    C = C0 + 1,
    Servers = rotate(First, Ids),
    spawn_op(clients, fun() -> peace_dst_client:command(Tab, C, Servers, C) end, S#{clients := C});
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
    ok = note_leaders(Views),
    first_violation([
        fun() -> storage_matches_memory(Views, Disks) end,
        fun() -> promise_never_regresses(Tab, Disks) end,
        fun() -> agreement(Tab, Disks) end,
        fun() -> applied_matches_decided(Views) end,
        fun() -> acknowledged_is_decided(Tab) end,
        fun() -> decided_once(Tab) end,
        fun() -> linearizable_read(Tab) end
    ]).

check_final(_Settled, #{converge := false}) ->
    ok;
check_final(Settled, #{tab := Tab, ids := Ids, converge := true}) ->
    Logs = [{Id, peace_core:decided(Core)} || Id <- Ids, {live, Core} <- [view(Id)]],
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
            case lists:usort([peace_core:decided(Core) || Id <- Ids, {live, Core} <- [view(Id)]]) of
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
    ok.

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

storage_matches_memory(Views, Disks) ->
    Wrong = [
        {Id, #{
            promised => {peace_core:promised(Core), Promised},
            only_in_memory => maps:without(maps:keys(Stored), Log),
            only_on_disk => maps:without(maps:keys(Log), Stored),
            differ => [I || {I, E} <- maps:to_list(Log), maps:get(I, Stored, E) =/= E]
        }}
     || {{Id, {live, Core}}, {Id, Promised, Stored}} <- lists:zip(Views, Disks),
        Log <- [peace_core:log(Core)],
        peace_core:promised(Core) =/= Promised orelse Log =/= Stored
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
%% something and was then killed still counts. Each slot's value is
%% remembered the first time anybody decides it and compared ever after.
agreement(Tab, Disks) ->
    Conflicts = [
        #{slot => I, server => Id, decided => Command, earlier => Earlier}
     || {Id, _Promised, Stored} <- Disks,
        {I, {decided, Command}} <- lists:sort(maps:to_list(Stored)),
        Earlier <- [remembered(Tab, {decided, I}, Command)],
        Earlier =/= Command
    ],
    case Conflicts of
        [] -> ok;
        _ -> violation(agreement, #{conflicts => Conflicts})
    end.

applied_matches_decided(Views) ->
    Wrong = [
        {Id, #{commit => Commit, applied => Applied, decided => Expected}}
     || {Id, {live, Core}} <- Views,
        Commit <- [peace_core:commit_index(Core)],
        Decided <- [peace_core:decided(Core)],
        Applied <- [lists:reverse(peace_core:machine_state(Core))],
        Expected <- [
            [{I, Command} || I <- lists:seq(1, Commit), {usr, Command} <- [maps:get(I, Decided, missing)]]
        ],
        Applied =/= Expected orelse
            not lists:all(fun(I) -> maps:is_key(I, Decided) end, lists:seq(1, Commit))
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(applied_matches_decided, #{servers => Wrong})
    end.

acknowledged_is_decided(Tab) ->
    Wrong = [
        #{op => Op, told => Index, decided => At}
     || [Op, Index] <- ets:match(Tab, {{op, '$1'}, {ok, '$2'}}),
        At <- [decided_at(Tab, Index)],
        At =/= {put, Op}
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(acknowledged_is_decided, #{commands => Wrong})
    end.

decided_once(Tab) ->
    Slots = lists:sort([{Op, I} || [I, {'$usr', _Tag, {put, Op}}] <- ets:match(Tab, {{decided, '$1'}, '$2'})]),
    case [{Op, I, J} || {{Op, I}, {Op, J}} <- lists:zip(lists:droplast([x | Slots]), Slots)] of
        [] -> ok;
        Twice -> violation(decided_once, #{commands => Twice})
    end.

linearizable_read(Tab) ->
    Wrong = [
        #{query => N, missing => Before -- Saw, saw => Saw}
     || [N, Before, Saw] <- ets:match(Tab, {{query, '$1'}, '$2', {ok, '$3'}}),
        Before -- Saw =/= [] orelse not is_decided_prefix(Tab, lists:reverse(Saw))
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(linearizable_read, #{queries => Wrong})
    end.

%% Whether `Ops', oldest first, is exactly the commands of some prefix of the
%% decided log.
is_decided_prefix(Tab, Ops) ->
    Decided = [
        Op
     || {_I, Command} <- lists:sort([{I, C} || [I, C] <- ets:match(Tab, {{decided, '$1'}, '$2'})]),
        {'$usr', _Tag, {put, Op}} <- [Command]
    ],
    lists:prefix(Ops, Decided).

decided_at(Tab, Index) ->
    case ets:lookup(Tab, {decided, Index}) of
        [{_, {'$usr', _Tag, Command}}] -> Command;
        [{_, {'$noop', _Tag}}] -> noop;
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
        Ballot -> Ballot
    end.

%% ---------------------------------------------------------------------------
%% The cluster
%% ---------------------------------------------------------------------------

server_config(I, Ids, Mode, Tab, Config) ->
    Base = #{
        id => lists:nth(I, Ids),
        members => Ids,
        machine => {module, peace_dst_machine, []},
        quorum => maps:get(quorum, Config, majority),
        storage => {peace_dst_storage, #{tab => Tab}},
        %% Short against the pace of the workload. A run injects its
        %% operations within a few virtual seconds, so an election that took
        %% one of them would leave most clients with nobody to talk to.
        election_timeout_ms => 50,
        heartbeat_ms => 10
    },
    case Mode of
        correct ->
            Base;
        unsafe_quorums ->
            Base#{quorum => {counting, 2, 1}, unsafe_no_quorum_check => true};
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

%% Ballots somebody led with. More than one in a run means leadership moved.
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
    bump(slots_decided, length(ets:match(Tab, {{decided, '_'}, '_'}))),
    catch ets:match_delete(?STATS, {{led, '_', '_'}, '_'}),
    ok.
