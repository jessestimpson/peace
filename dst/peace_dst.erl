%% This module is the eta harness for a peace cluster. The harness starts the
%% cluster, runs a workload of client operations and faults against the
%% cluster, and checks invariants on the cluster.
%%
%% == Simulated system ==
%%
%% The harness starts `servers' (default 3) peace servers on one VM.
%%
%% <ul>
%% <li>Each server is a `gen_server' that the scheduler steps.</li>
%% <li>Each server runs on a separate simulated node.</li>
%% <li>The election timers and the heartbeat timers run on the virtual
%%   clock.</li>
%% <li>Every message between servers goes through `eta_net'. The network
%%   policy of the run may drop or delay a message.</li>
%% <li>All clients share one additional node.</li>
%% <li>The storage of each server is `peace_dst_storage', an ETS table that
%%   the harness owns. A server that is killed and then restarted therefore
%%   reads back the promise and the log that the server wrote before the
%%   kill.</li>
%% </ul>
%%
%% This is the fault model that `formal/FlexiblePaxos.tla' assumes:
%%
%% <ul>
%% <li>Messages are lost.</li>
%% <li>Messages are in effect duplicated, because servers retransmit.</li>
%% <li>Messages are delayed.</li>
%% <li>Servers stop, and restart with their durable state.</li>
%% </ul>
%%
%% == Workload ==
%%
%% Clients submit values and linearizable reads. When `faults' is on, the
%% workload also contains these fault operations:
%%
%% <ul>
%% <li>cut one server off from the other servers;</li>
%% <li>heal every cut;</li>
%% <li>kill a server;</li>
%% <li>restart a server.</li>
%% </ul>
%%
%% The harness generates a fault in the same way as any other operation. The
%% seed therefore determines the position of each fault in the run. Each
%% fault is recorded in the trace, and a replay of the trace repeats the
%% fault.
%%
%% == Invariants ==
%%
%% The harness checks these invariants after every step:
%%
%% <ul>
%% <li>`storage_matches_memory' - the promise, the accepted entries and the
%%   snapshot index that a server holds in memory are equal to the promise,
%%   the entries and the snapshot index on the disk of that server, after
%%   the writes that the server has sent to its storage process and that
%%   have not returned are applied to the disk. This invariant checks, from
%%   outside the server, that the server has sent a write for every change
%%   to its durable state.</li>
%% <li>`promise_never_regresses' - the durable promise of a server never
%%   decreases.</li>
%% <li>`agreement' - no index is decided with two different values, by any
%%   server, at any time in the run. This is TLA+ `LearnedAgree'.</li>
%% <li>`applied_matches_decided' - the machine of a server has applied
%%   exactly the decided log up to the commit index of the server, in order,
%%   and has applied the value of each session once. The decided log is a
%%   record that the harness keeps. A server that received a snapshot is
%%   therefore checked against the same record as a server that applied
%%   every entry.</li>
%% <li>`acknowledged_is_decided' - when a client receives `{ok, Index}', the
%%   value of that client is decided at that index.</li>
%% <li>`applied_once' - no machine has applied a value twice, regardless of
%%   how many indexes hold the value because of client retries.</li>
%% <li>`session_order' - every machine has applied the values of each
%%   session process in the order in which the client submitted them, with
%%   no value left out. This invariant applies to the clients of
%%   `retry => pipeline'.</li>
%% <li>`linearizable_read' - a consistent query returns a prefix of the
%%   decided log, and the prefix contains every value that was acknowledged
%%   before the query was issued.</li>
%% </ul>
%%
%% At the end of a run with `converge' on, the harness also checks that:
%%
%% <ul>
%% <li>every server has applied the same indexes and has the same state;</li>
%% <li>at least one value was acknowledged.</li>
%% </ul>
%%
%% Servers take a snapshot every few indexes. Every run therefore includes
%% log truncation, recovery from a snapshot, and catch-up from a snapshot
%% that another server sends. A server sends a snapshot in chunks of 48
%% bytes, so the faults of a run also occur between the chunks of a
%% snapshot.
%%
%% Clients submit values under a session. A client retries a request when the
%% outcome of the request is unknown.
%%
%% `retry => pipeline' replaces the client of a value. The client starts a
%% session process (`peace_session') and submits three values, which are
%% undecided at the same time. See `peace_dst_client:pipeline/3'.
%%
%% == Membership ==
%%
%% With `reconfigure' on, the first three servers are the initial members of
%% the cluster. The remaining servers run outside the cluster and wait for
%% messages from the cluster.
%%
%% The workload has one additional operation. The operation asks the current
%% leader to change to another configuration from a fixed list. Compared
%% with the current configuration, a configuration in the list can have:
%%
%% <ul>
%% <li>different members;</li>
%% <li>more members;</li>
%% <li>fewer members;</li>
%% <li>no member in common;</li>
%% <li>a different quorum system.</li>
%% </ul>
%%
%% The harness checks every invariant above in the same way, across every
%% configuration that the run uses. The convergence check applies to the
%% members of the last configuration.
%%
%% == Disks and clocks ==
%%
%% `disk => dets' runs the shipped `peace_storage_dets' backend behind the
%% disk of the simulation. See `peace_dst_storage'.
%%
%% `disk => wal' runs the shipped `peace_storage_wal' backend in the same
%% way. A run with `disk => wal' must also set the eta run option
%% `disk => true'. That option starts the simulated disk of eta
%% (`eta_disk'). When the node of a server is killed, the simulated disk
%% loses the file data and the directory operations that the server did not
%% sync. The dets backend runs on `eta_dets', which loses nothing.
%%
%% `clock_drift => P' makes the clocks of two servers in every three run P
%% per cent fast. Clock drift affects only read leases. A lease allows for a
%% drift of one tenth. When the drift is far enough beyond one tenth, a read
%% returns stale state.
%%
%% == Client history ==
%%
%% `history => Table' copies the client history of the run into the ETS
%% table `Table' when the run ends. The caller creates the table and owns
%% it. `peace_dst_history' describes the history. `make porcupine' checks
%% the histories with Porcupine.
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
%% `mode' selects one planted bug. The suite uses the planted bugs to show
%% that each check can fail:
%%
%% <ul>
%% <li>`unsafe_quorums' - the quorum system is `{counting, 2, 1}' over three
%%   servers, and the quorum validation of the server is switched off. These
%%   are the same constants as `formal/FPaxosUnsafeQuorums.cfg'.</li>
%% <li>`amnesia' - the disk of a server is empty after a restart.</li>
%% <li>`lossy_disk' - with `disk => dets', the dets backend runs behind a
%%   layer that does not write promises. This mode shows that
%%   `disk_recovers' can fail.</li>
%% <li>`unsynced_wal' - with `disk => wal', the write-ahead log backend
%%   never syncs. See `peace_dst_nosync_io'. This mode shows that
%%   `disk_recovers' can fail when a kill loses unsynced data.</li>
%% <li>`no_snapshot_guard' - a candidate becomes leader on a promise from an
%%   acceptor that has dropped indexes that the candidate never learned.
%%   This is the same change as `formal/FPaxosNoSnapshotGuard.cfg'.</li>
%% <li>`no_joint' - a membership change goes directly to the new
%%   configuration. This is the same change as
%%   `formal/ReconfigNoJoint.cfg'.</li>
%% <li>`no_lease_fence' - with read leases on, servers promise other epochs
%%   while a leader still relies on those servers for its lease, and a
%%   deposed leader answers a read from the stale state of that leader.</li>
%% <li>`bare_retries' - clients retry without a session, and a value is
%%   applied twice. This mode is not a bug in peace. This mode shows that
%%   `applied_once' can fail.</li>
%% <li>`unordered_sessions' - with `retry => pipeline', a server applies a
%%   value of a session although the value with the previous sequence number
%%   is not applied. This mode shows that `session_order' can fail.</li>
%% <li>`no_conflict_step_down' - a leader learns that an index was decided
%%   with a value other than the value that the leader proposed, and the
%%   leader continues to lead. This is the same change as
%%   `formal/FPaxosNoConflictStepDown.cfg'.</li>
%% </ul>
%%
%% == Churn ==
%%
%% With `churn' on, the workload tests leadership changes instead of
%% durability. The workload generates neither `{crash, I}' nor
%% `{restart, I}'. It generates three additional operations in their place:
%%
%% <ul>
%% <li>`{elect, I}' - the harness tells a server that the election timeout
%%   of the server has fired, although the timeout has not fired. Any server
%%   may suspect its leader at any time.</li>
%% <li>`{split, I, J}' - the harness cuts two servers off together from the
%%   other servers. A leader can then keep one follower while another server
%%   becomes leader, and neither the first leader nor that follower receives
%%   a message about the new leader.</li>
%% <li>`{rumour, I}' - a server receives a `learned' message for the latest
%%   indexes that any server has decided. The message is delivered
%%   regardless of any cut. The message represents an answer to a catch-up
%%   request that was sent long before and arrives only now. The message
%%   corresponds to the TLA+ `CatchUp' action, which the model allows for
%%   any server at any time. The network policy alone almost never produces
%%   this message, because a server that becomes leader sends catch-up
%%   requests only while that server is still a follower.</li>
%% </ul>
%%
%% Together, the three operations reach the stale-leader hazard that
%% `ConflictStepDown' in the model guards against. Random loss and delay did
%% not reach this hazard in thousands of runs.
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
    %% The modules in dst/ are not part of the peace application, so
    %% `preload => [peace]' does not load them. The harness loads them here.
    %% Loading a module during a run would make a call to the code server,
    %% and the scheduler does not control the code server.
    [{module, M} = code:ensure_loaded(M) || M <- [peace_dst_client, peace_dst_machine, peace_dst_storage, peace_dst_lossy_disk, peace_dst_nosync_io, peace_dst_trace, peace_dst_history]],
    %% The table is an `ordered_set', so that reading the disk of one server
    %% is a range read and not a scan of the whole table.
    Tab = ets:new(peace_dst, [public, ordered_set]),
    Ids = [id(I) || I <- lists:seq(1, N)],
    Reconfigure = maps:get(reconfigure, Config, false),
    %% `Founders' are the initial members of the cluster. The other servers
    %% are configured with the same list of members, and wait.
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
    %% No server is started here. The first operation of every run is
    %% `boot', which starts every server. See `generate/2'. A server starts its
    %% storage process from `init/1'. A start from this function would wait
    %% on that child process, which the scheduler does not release before
    %% the run begins.
    %%
    %% Each server has its own simulated node, as in a deployment. The
    %% restarter process of a server is placed on the node, and the server
    %% and its storage process inherit the node. Placement defines the
    %% effect of each fault:
    %%   - A cut is between nodes, so a cut stays in place when a server
    %%     restarts.
    %%   - A kill stops every process on the node.
    %% Placing no process on a node creates the node.
    [ok = eta_net:place(node_name(I), []) || I <- lists:seq(1, N)],
    %% All server nodes are connected to each other at the start, as the
    %% nodes of a cluster are immediately after boot.
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
                unordered_sessions -> pipeline;
                _ -> maps:get(retry, Config, session)
            end,
        converge => maps:get(converge, Config, false),
        %% A table that receives the client history when the run ends, or
        %% `undefined'. See `peace_dst_history'.
        history => maps:get(history, Config, undefined),
        %% `ops' lists every process that the run has started through
        %% `spawn_op/3', oldest first. These are the processes of the value,
        %% query, reconfigure, elect and rumour operations.
        ops => [],
        %% `sups' lists every restarter process, oldest first. A restarter
        %% stays alive for as long as the server that the restarter started.
        %% The restarter is linked to that server, as a supervisor is.
        sups => [],
        %% `pipes' lists every client of `retry => pipeline', oldest first,
        %% with the number of the client. Such a client stays alive after
        %% it has recorded its results. See `peace_dst_client:pipeline/3'.
        pipes => [],
        %% Whether the run has started the servers. See `generate/2'.
        booted => false,
        clients => 0
    }}.

%% Returns the servers in index order, then the operation processes in order
%% of age. A restarted server is a child of the operation process that
%% restarted the server, and the scheduler adopts the server together with
%% that process. Listing the server here as well is harmless, and makes the
%% order of the list a function of the run.
processes(#{n := N, ops := Ops, sups := Sups, pipes := Pipes}) ->
    [Pid || I <- lists:seq(1, N), Pid <- [server_pid(I)], is_pid(Pid)] ++
        [Pid || Pid <- Ops ++ Sups ++ [Pipe || {_C, Pipe} <- Pipes], is_process_alive(Pid)].

%% The first operation of a run starts every server at the same time. The
%% operation makes no random draw.
generate(#{booted := false}, Rand) ->
    {boot, Rand};
generate(S = #{reconfigure := true}, Rand0) ->
    %% A run with `reconfigure' on makes one more random draw per operation
    %% than a run with `reconfigure' off. The extra draw is made only in
    %% this clause, so that the run that a seed produces with `reconfigure'
    %% off is unchanged.
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
            %% Faults are rare. With too many faults no value ever completes,
            %% and only a completed value can violate an invariant.
            Roll < 0.62 -> {value, I};
            Roll < 0.80 -> {query, I};
            Roll < 0.84 -> {isolate, I};
            Roll < 0.91 -> heal;
            Roll < 0.94 -> {crash, I};
            true -> {restart, I}
        end,
    {Op, Rand2}.

%% A client operation names the server that the client tries first by index.
%% The identity of an operation is the position of the operation in the run.
%% An operation contains no pid, no ref and no generated name, so a trace can
%% be replayed.
execute({value, First}, S = #{tab := Tab, ids := Ids, clients := C0}) ->
    C = C0 + 1,
    Servers = rotate(First, Ids),
    case maps:get(retry, S) of
        pipeline ->
            Pid = eta_run:spawn_op(fun() -> peace_dst_client:pipeline(Tab, C, Servers) end),
            ok = eta_net:place(clients, [Pid]),
            S#{clients := C, pipes := maps:get(pipes, S) ++ [{C, Pid}]};
        Retry ->
            spawn_op(clients, fun() -> peace_dst_client:value(Tab, C, Servers, C, Retry) end, S#{clients := C})
    end;
execute({query, First}, S = #{tab := Tab, ids := Ids, clients := C0}) ->
    C = C0 + 1,
    Servers = rotate(First, Ids),
    spawn_op(clients, fun() -> peace_dst_client:query(Tab, C, Servers) end, S#{clients := C});
%% An isolation is a message fault and not a node failure. Both ends of the
%% link continue to treat the link as up. peace cannot observe more than
%% that, because peace detects failure by the absence of messages and not by
%% `nodedown'.
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
            %% Every process on the node dies at once, between steps, and the
            %% kill waits until the processes are dead. The disk of the
            %% server belongs to the harness and keeps its contents. With
            %% `disk => wal', the simulated disk of eta decides which
            %% unsynced data in the files of the server remains.
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
            %% The message is sent from the node of the receiver. The message
            %% represents a message that was already in flight before the
            %% cuts that exist now were made.
            spawn_op(node_name(I), fun() -> peace_dst_client:deliver(To, From, {learned, Latest}) end, S)
    end;
execute(boot, S = #{n := N}) ->
    lists:foldl(fun(I, Acc) -> execute({restart, I}, Acc) end, S#{booted := true}, lists:seq(1, N));
execute({restart, I}, S = #{configs := Configs}) ->
    case server_pid(I) of
        undefined ->
            Config = maps:get(I, Configs),
            bump(restarts),
            %% The server is a child of the restarter process and inherits
            %% the node of the restarter process.
            Pid = eta_run:spawn_op(fun() -> peace_dst_client:restart(Config) end),
            ok = eta_net:place(node_name(I), [Pid]),
            S#{sups := maps:get(sups, S) ++ [Pid]};
        _Running ->
            S
    end.

check(#{tab := Tab, ids := Ids}) ->
    Views = [{Id, view(Id)} || Id <- Ids],
    Disks = [{Id, stored_promised(Tab, Id), peace_dst_storage:entries(Tab, Id)} || Id <- Ids],
    %% A server acts on a decision before the write of the `learned' entry
    %% has returned. The entries of the writes that are in progress are
    %% added to the record of decided values here.
    _ = [ok = peace_dst_storage:decided(Tab, Id, Batch) || Id <- Ids, Batch <- inflight(Id)],
    Record = decided_record(Tab),
    ok = note_leaders(Views),
    first_violation([
        fun() -> disk_recovers(Tab) end,
        fun() -> storage_matches_memory(Tab, Views, Disks) end,
        fun() -> promise_never_regresses(Tab, Disks) end,
        fun() -> agreement(Tab, Disks) end,
        fun() -> session_order(Views) end,
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

%% The workload is finished when every client has received its answer. A
%% cluster with a heartbeat never becomes idle, so without this callback
%% every run would use its whole settle budget on heartbeat steps. When
%% `converge' is on, this callback also waits until the servers have
%% converged.
settle_done(#{tab := Tab, ops := Ops, pipes := Pipes, converge := Converge, ids := Ids}) ->
    not lists:any(fun is_process_alive/1, Ops) andalso
        lists:all(fun({C, _Pid}) -> ets:member(Tab, {pipeline_done, C}) end, Pipes) andalso
        (not Converge orelse
            case lists:usort([applied(Core) || {_Id, Core} <- current_members(Ids)]) of
                [_One] -> true;
                _ -> false
            end).

terminate(S = #{tab := Tab, n := N}) ->
    ok = record_stats(Tab),
    ok = peace_dst_history:copy(Tab, maps:get(history, S)),
    %% The restarters are killed first. A server that a restarter has started
    %% but that has not yet registered its name can only be reached through
    %% the link to the restarter.
    ok = kill(maps:get(sups, S)),
    Sessions = [Pid || [Pid] <- ets:match(Tab, {{session, '_'}, '$1'})],
    ok = kill([Pid || {_C, Pid} <- maps:get(pipes, S)] ++ Sessions),
    ok = kill(maps:get(ops, S) ++ [Pid || I <- lists:seq(1, N), Pid <- [server_pid(I)], is_pid(Pid)]),
    ok = await_unregistered(N, 1000),
    catch ets:delete(Tab),
    ok = clear_disk(),
    ok.

%% Returns the directory in which `disk => dets' and `disk => wal' keep
%% their files. Every run
%% uses this one directory, so that the name of the directory is the same in
%% every run. The harness empties the directory before and after each run.
disk_dir() ->
    filename:join(filename:basedir(user_cache, "peace_dst"), "disk").

%% This function uses `prim_file' because the file server is a process that
%% no schedule controls. The dets backend keeps files in the directory. The
%% write-ahead log backend keeps one directory per server.
clear_disk() ->
    clear_dir(disk_dir()).

clear_dir(Dir) ->
    case prim_file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(
                fun(Name) ->
                    Path = filename:join(Dir, Name),
                    case prim_file:delete(Path) of
                        ok ->
                            ok;
                        {error, _} ->
                            ok = clear_dir(Path),
                            ok = prim_file:del_dir(Path)
                    end
                end,
                Names
            );
        {error, enoent} ->
            ok
    end.

%% Kills the processes and waits until each process is dead, so that no
%% process from this run is still terminating when the next run starts.
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

%% This invariant applies with `disk => dets' and `disk => wal'. A server
%% that opened its files recovered the state that the server had written. The state that the
%% server had written is the state that the disk of the simulation holds.
disk_recovers(Tab) ->
    case ets:match(Tab, {{disk_differs, '$1'}, '$2', '$3'}) of
        [] -> ok;
        Differ -> violation(disk_recovers, #{servers => [{Id, #{recovered => D, wrote => W}} || [Id, D, W] <- Differ]})
    end.

%% A server sends its writes to its storage process and does not wait for
%% them. The disk is therefore compared with the memory of the server after
%% the writes that are in progress have been applied to the contents of the
%% disk. A write that has returned and that the server has not yet been told
%% of is applied twice, which changes nothing.
storage_matches_memory(Tab, Views, Disks) ->
    Wrong = [
        {Id, #{
            promised => {peace_core:promised(Core), Promised},
            snapshot => {peace_core:snapshot_index(Core), Snap},
            only_in_memory => maps:without(maps:keys(Stored), Log),
            only_on_disk => maps:without(maps:keys(Log), Stored),
            differ => [I || {I, E} <- maps:to_list(Log), maps:get(I, Stored, E) =/= E]
        }}
     || {{Id, {live, Core}}, {Id, Promised0, Stored0}} <- lists:zip(Views, Disks),
        Log <- [peace_core:log(Core)],
        {Promised, Stored, Snap} <- [
            lists:foldl(
                fun apply_batch/2,
                {Promised0, Stored0, peace_dst_storage:snapshot_index(Tab, Id)},
                %% A snapshot may be stored after a write that was sent
                %% later. The snapshots are applied first. `apply_batch/2'
                %% then removes the entries under them from each write.
                snapshots(Id) ++ inflight(Id)
            )
        ],
        peace_core:promised(Core) =/= Promised orelse Log =/= Stored orelse
            peace_core:snapshot_index(Core) =/= Snap
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(storage_matches_memory, #{servers => Wrong})
    end.

%% Applies a write to the contents of a disk.
apply_batch(Batch, {Promised0, Entries0, Snap0}) ->
    Promised = maps:get(promised, Batch, Promised0),
    Snap =
        case Batch of
            #{snapshot := {Index, _}} -> Index;
            _ -> Snap0
        end,
    Entries = maps:merge(Entries0, maps:from_list(maps:get(entries, Batch, []))),
    {Promised, maps:filter(fun(I, _) -> I > Snap end, Entries), Snap}.

%% Returns the writes that a server has sent to its storage process and
%% that have not returned, in order.
inflight({Name, Node}) ->
    case server_pid(Name, Node) of
        undefined ->
            [];
        Pid ->
            case eta_observe:read(Pid) of
                #{inflight := Inflight} -> [Batch || {_Seq, Batch} <- Inflight];
                _ -> []
            end
    end.

%% Returns the snapshots that a server has sent to its storage process and
%% that are not yet stored, in order.
snapshots({Name, Node}) ->
    case server_pid(Name, Node) of
        undefined ->
            [];
        Pid ->
            case eta_observe:read(Pid) of
                #{snapshots := Snapshots} -> Snapshots;
                _ -> []
            end
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

%% The check reads the disks and not the servers, so that the check includes
%% a server that decided a value and was then killed. The first time any
%% server decides an index, the check stores the value of that index. The
%% check compares every later decision of that index with the stored value.
agreement(Tab, Disks) ->
    Conflicts =
        [
            #{index => I, server => Id, decided => Value, earlier => Earlier}
         || {Id, _Promised, Stored} <- Disks,
            {I, {learned, Value}} <- lists:sort(maps:to_list(Stored)),
            Earlier <- [remembered(Tab, {decided, I}, Value)],
            Earlier =/= Value
        ] ++
            %% The disk recorded these conflicts at the time of the write.
            %% See `peace_dst_storage'.
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

%% Returns the state that a machine holds after the first `Commit' indexes
%% of the decided log. The state contains:
%%   - every value that has no session;
%%   - each value of a session whose sequence number is one above the
%%     sequence number of the last value of that session in the state.
%% Returns `{missing, I}' if the record has no value at an index `I' that is
%% at or below `Commit'. The commit index of a server must never be beyond
%% the end of the record.
expected(Commit, Record) ->
    expected(1, Commit, Record, #{}, []).

expected(I, Commit, _Record, _Sessions, Acc) when I > Commit ->
    lists:reverse(Acc);
expected(I, Commit, Record, Sessions, Acc) ->
    case Record of
        #{I := {'$usr', _Tag, Value}} ->
            expected(I + 1, Commit, Record, Sessions, [{I, Value} | Acc]);
        #{I := {'$ses', _Tag, {Client, Seq}, Value}} ->
            case maps:get(Client, Sessions, 0) + 1 of
                Seq -> expected(I + 1, Commit, Record, Sessions#{Client => Seq}, [{I, Value} | Acc]);
                _ -> expected(I + 1, Commit, Record, Sessions, Acc)
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

%% Returns the live members of the latest configuration that any server
%% holds. The latest configuration is the configuration in force at the
%% live server that has the highest commit index. A server that was removed
%% from the configuration no longer receives messages and is not expected to
%% stay up to date.
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

%% Returns the configurations that a run changes between. Over five servers,
%% the configurations are:
%%   - the founders;
%%   - a set that shares one server with the founders;
%%   - all five servers, with two servers needed to commit;
%%   - a pair with no server in common with the founders;
%%   - four servers.
targets(#{ids := Ids}) ->
    Pick = fun(Is) -> [lists:nth(I, Ids) || I <- Is, I =< length(Ids)] end,
    [
        {Pick([1, 2, 3]), majority},
        {Pick([3, 4, 5]), majority},
        {Pick([1, 2, 3, 4, 5]), {counting, 4, 2}},
        {Pick([4, 5]), majority},
        {Pick([1, 2, 4, 5]), {counting, 3, 2}}
    ].

%% Returns the value that is compared between servers at the end of a run:
%% the index up to which the server has applied, and the resulting machine
%% state.
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

%% The operation of a client of `retry => pipeline' is `{N, K}': value `K'
%% of client `N'. The values of client `N' that a machine has applied must
%% be the values 1 to some `K', in that order.
session_order(Views) ->
    Wrong = [
        {Id, N, Ks}
     || {Id, {live, Core}} <- Views,
        {N, Ks} <- maps:to_list(
            lists:foldl(
                fun({N, K}, Acc) -> Acc#{N => maps:get(N, Acc, []) ++ [K]} end,
                #{},
                [Op || {_I, {put, Op = {_N, _K}}} <- lists:reverse(peace_core:machine_state(Core))]
            )
        ),
        Ks =/= lists:seq(1, length(Ks))
    ],
    case Wrong of
        [] -> ok;
        _ -> violation(session_order, #{servers => Wrong})
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

%% Returns whether `Ops', oldest first, is equal to the state that a machine
%% holds after some prefix of the decided log.
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

%% `eta_shrink' uses the `property' key to distinguish one failure from
%% another.
violation(Property, Detail) ->
    {violation, Detail#{property => Property}}.

%% Returns the value that was first stored under `Key'. Stores `Value' if no
%% value is stored under `Key' yet.
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
        %% The tracer records every step of every server, in the order in
        %% which the steps were taken. `peace_dst_trace' checks the steps
        %% against the model. The caller owns the table, so the table still
        %% exists after the run.
        #{trace := Trace} ->
            Server#{
                test_tracer => fun
                    ({performed, _}) ->
                        N = ets:update_counter(Trace, seq, 1, {seq, 0}),
                        ets:insert(Trace, {N, Id, performed});
                    ({_, Event, Before, After, Effects}) ->
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
                #{tab => Tab, node => node_name(I), disk => {peace_storage_dets, #{dir => disk_dir()}}};
            {wal, unsynced_wal} ->
                Args = #{dir => disk_dir(), io => peace_dst_nosync_io, checkpoint_chunk_bytes => 48},
                #{tab => Tab, node => node_name(I), disk => {peace_storage_wal, Args}};
            {wal, _} ->
                #{tab => Tab, node => node_name(I), disk => {peace_storage_wal, #{dir => disk_dir(), checkpoint_chunk_bytes => 48}}}
        end,
    Base = #{
        id => Id,
        members => Founders,
        machine => {module, peace_dst_machine, []},
        quorum => maps:get(quorum, Config, majority),
        storage => {peace_dst_storage, Storage},
        %% The election timeout is short relative to the rate of the
        %% workload. A run injects its operations within a few virtual
        %% seconds. An election that took one of those seconds would leave
        %% most clients without a leader to contact.
        election_timeout_ms => maps:get(election_timeout_ms, Config, 50),
        heartbeat_ms => 10,
        %% The snapshot interval is small enough that every run truncates the
        %% log, restarts a server from a snapshot and sends a snapshot.
        snapshot_interval => maps:get(snapshot_interval, Config, 5),
        %% A snapshot of the machine of the simulation is a few hundred
        %% bytes. The chunk size is small enough that a server sends every
        %% snapshot in several chunks.
        snapshot_chunk_bytes => maps:get(snapshot_chunk_bytes, Config, 48)
    },
    Leased0 = maps:merge(Base, maps:with([read_lease_ms, propose_to, max_pending], Config)),
    %% The clocks of the servers run at different rates. The clock of every
    %% third server runs at the true rate. The clocks of the other servers
    %% run fast by `clock_drift' per cent, so those servers measure the end
    %% of a lease earlier than a leader with a true clock does. (A server
    %% with a slow clock is not a hazard: the slow server stays bound by the
    %% lease for longer, and so stays out of elections for longer.) The
    %% clock of the simulation is the true clock, and timers run on the
    %% clock of the simulation.
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
        unordered_sessions ->
            Leased#{unsafe_no_session_order => true};
        lossy_disk ->
            Base;
        unsynced_wal ->
            Base;
        amnesia ->
            Base#{storage => {peace_dst_storage, #{tab => Tab, amnesia => true}}}
    end.

%% A server that was starting when the previous run was torn down dies with
%% its restarter. The server may have registered its name before the server
%% died.
clear_leftovers(N) ->
    ok = kill([Pid || I <- lists:seq(1, N), Pid <- [whereis(name(I))], is_pid(Pid)]),
    await_unregistered(N, 1000).

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

%% The new process is blocked until the scheduler adopts the process. The
%% process is therefore placed on its node before the process executes any
%% code.
spawn_op(Node, Fun, S = #{ops := Ops}) ->
    Pid = eta_run:spawn_op(Fun),
    ok = eta_net:place(Node, [Pid]),
    S#{ops := Ops ++ [Pid]}.

%% Returns the protocol state of a server. The read does not send a message
%% to the server.
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

%% A server started in `init/2' registered its name before the harness
%% placed the server on a node, so the name is in the namespace of the VM. A
%% server restarted during the run started on its node, and registered its
%% name in the namespace of that node.
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
%% Statistics
%%
%% The statistics show whether the runs exercised the behaviour that the
%% runs were meant to exercise. A sweep has checked nothing if the sweep
%% passes because no client ever received an answer, or because the leader
%% never changed. The suite owns a table. The harness adds the counts of
%% each run to the table. The suite asserts on the totals.
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

%% Records each epoch in which a server was leader. More than one such epoch
%% in a run means that leadership changed.
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
