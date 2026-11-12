%% @doc A benchmark harness for peace. See bench/README.md for the method
%% and the results.
%%
%% The harness runs on a controller node. It starts each server on a
%% separate Erlang node on the same machine, with the `peer' module. The
%% clients are processes on the controller node. The clients reach the
%% servers over Erlang distribution.
%%
%% Run the harness with `bench/run.sh <suite>'. The suites are listed in
%% `suite/1'.
-module(peace_bench).

-export([main/1]).
%% Called on a server node through `erpc'.
-export([remote_overview/1]).

-define(SERVER, peace_bench).
-define(WARMUP_MS, 2000).
-define(MEASURE_MS, 10000).
-define(KEYS, 1000).
-define(VALUE_BYTES, 100).

%% ---------------------------------------------------------------------------
%% Entry point
%% ---------------------------------------------------------------------------

-spec main([string()]) -> no_return().
main(Suites) ->
    io:format("OTP ~s, ~b schedulers on the controller, ~s~n", [
        erlang:system_info(otp_release), erlang:system_info(schedulers), node_flags_text()
    ]),
    try
        lists:foreach(fun(S) -> suite(list_to_atom(S)) end, Suites),
        halt(0)
    catch
        Class:Reason:Stack ->
            io:format("FAILED ~p:~p~n~p~n", [Class, Reason, Stack]),
            halt(1)
    end.

suite(all) ->
    lists:foreach(fun suite/1, [throughput, value_size, propose_to, reads, failover, restart, catch_up]);
suite(smoke) ->
    with_cluster(#{servers => 3, storage => mem}, fun(C) ->
        header(load),
        run_load("smoke", C, #{clients => 4, measure_ms => 1000, warmup_ms => 200})
    end);
%% Writes. 3 and 5 servers, each storage backend, 1 to 256 clients.
suite(throughput) ->
    header(load),
    [
        with_cluster(#{servers => N, storage => Storage}, fun(C) ->
            [
                run_load(io_lib:format("~b servers, ~s", [N, Storage]), C, #{clients => Clients})
             || Clients <- [1, 4, 16, 64, 256]
            ]
        end)
     || Storage <- [mem, dets, wal], N <- [3, 5]
    ],
    ok;
%% Writes with values of 100 bytes to 100 kB.
suite(value_size) ->
    header(load),
    [
        with_cluster(#{servers => 3, storage => Storage}, fun(C) ->
            [
                run_load(io_lib:format("3 servers, ~s, ~b-byte values", [Storage, Bytes]), C, #{
                    clients => 16, value_bytes => Bytes
                })
             || Bytes <- [100, 1000, 10000, 100000]
            ]
        end)
     || Storage <- [mem, dets, wal]
    ],
    ok;
%% Writes to 5 servers, with each quorum system and each `propose_to'.
suite(propose_to) ->
    header(load),
    [
        with_cluster(#{servers => 5, storage => Storage, opts => #{quorum => Quorum, propose_to => To}}, fun(C) ->
            run_load(io_lib:format("5 servers, ~s, ~p, propose_to ~s", [Storage, Quorum, To]), C, #{clients => 16})
        end)
     || Storage <- [mem, wal], Quorum <- [majority, {counting, 4, 2}], To <- [all, quorum]
    ],
    ok;
%% The four kinds of read, on 3 servers.
suite(reads) ->
    header(load),
    [
        begin
            with_cluster(#{servers => 3, storage => Storage}, fun(C) ->
                [
                    run_load(io_lib:format("3 servers, ~s, ~s", [Storage, Text]), C, #{clients => 16, op => Op})
                 || {Op, Text} <- [
                        {get, "get (proposed)"},
                        {read, "read (consistent_query, no lease)"},
                        {stale_read, "stale_read (local_query)"}
                    ]
                ]
            end),
            with_cluster(#{servers => 3, storage => Storage, opts => #{read_lease_ms => 1000}}, fun(C) ->
                run_load(io_lib:format("3 servers, ~s, read (consistent_query, lease)", [Storage]), C, #{
                    clients => 16, op => read
                })
            end)
        end
     || Storage <- [mem, wal]
    ],
    ok;
%% The time for which no value is decided after the leader's node is killed.
suite(failover) ->
    header(failover),
    [
        with_cluster(#{servers => N, storage => wal, opts => #{election_timeout_ms => T}}, fun(C) ->
            Times = failover_trials(C, 10),
            row(failover, [io_lib:format("~b servers, election timeout ~b ms", [N, T]) | summary(Times)])
        end)
     || N <- [3, 5], T <- [1000, 100]
    ],
    ok;
%% The time for a follower to restart with a machine state of a given size.
suite(restart) ->
    header(restart),
    [
        with_cluster(#{servers => 3, storage => Storage, opts => #{snapshot_interval => 64}}, fun(C) ->
            restart_trial(C, Storage, MB)
        end)
     || Storage <- [dets, wal], MB <- [1, 10, 100]
    ],
    ok;
%% The time for a follower to catch up after it missed a number of values.
%% The heartbeat interval is one fifth of the election timeout.
suite(catch_up) ->
    header(catch_up),
    [
        with_cluster(#{servers => 3, storage => wal, opts => #{election_timeout_ms => T}}, fun(C) ->
            catch_up_trial(C, T div 5, Missed)
        end)
     || T <- [1000, 100], Missed <- [100, 1000, 3000, 10000]
    ],
    ok.

%% ---------------------------------------------------------------------------
%% Clusters
%% ---------------------------------------------------------------------------

%% Starts a cluster, calls `Fun' with the cluster, and stops the cluster.
with_cluster(Spec, Fun) ->
    C = start_cluster(Spec),
    try
        Fun(C)
    after
        stop_cluster(C)
    end.

start_cluster(Spec = #{servers := N, storage := StorageKind}) ->
    Dir = filename:join(["_build", "bench", "data", integer_to_list(erlang:unique_integer([positive]))]),
    Storage =
        case StorageKind of
            mem -> {peace_storage_mem, #{}};
            dets -> {peace_storage_dets, #{dir => filename:absname(Dir)}};
            wal -> {peace_storage_wal, #{dir => filename:absname(Dir)}}
        end,
    Names = [list_to_atom("peace_bench_" ++ integer_to_list(I)) || I <- lists:seq(1, N)],
    Peers = maps:from_list([start_node(Name) || Name <- Names]),
    Ids = [{?SERVER, Node} || Node <- lists:sort(maps:keys(Peers))],
    Opts = maps:merge(#{storage => Storage}, maps:get(opts, Spec, #{})),
    {ok, Ids, []} = peace:start_cluster(Ids, peace_kv:machine(), Opts),
    ok = peace:trigger_election(hd(Ids)),
    C = #{ids => Ids, peers => Peers, opts => Opts, dir => Dir},
    _ = await_leader(C),
    C.

%% Stops every server node by name. A node that a trial restarted has a
%% peer process that the caller's cluster map does not contain, so the peer
%% processes are not used here.
stop_cluster(#{ids := Ids, dir := Dir}) ->
    lists:foreach(
        fun({_Name, Node}) ->
            true = erlang:monitor_node(Node, true),
            ok = erpc:cast(Node, erlang, halt, [0, [{flush, false}]]),
            receive
                {nodedown, Node} -> ok
            after 10000 -> error({node_did_not_stop, Node})
            end
        end,
        Ids
    ),
    _ = file:del_dir_r(Dir),
    ok.

%% Starts a server node and the peace application on it. The node has the
%% code path of the controller. Returns `{Node, Peer}'.
start_node(Name) ->
    Paths = lists:append([["-pa", P] || P <- code:get_path(), lists:prefix(filename:absname("_build"), P)]),
    %% `global' disconnects nodes to prevent overlapping partitions. It would
    %% disconnect nodes of the next cluster when the harness stops the nodes
    %% of a cluster.
    Args =
        Paths ++
            ["-setcookie", atom_to_list(erlang:get_cookie())] ++
            ["-kernel", "prevent_overlapping_partitions", "false"] ++
            node_flags(),
    {ok, Peer, Node} = peer:start(#{name => Name, args => Args, wait_boot => 60000}),
    {ok, _} = erpc:call(Node, application, ensure_all_started, [peace]),
    {Node, Peer}.

%% Extra emulator flags for the server nodes, from the environment variable
%% PEACE_BENCH_NODE_FLAGS.
node_flags() ->
    string:lexemes(os:getenv("PEACE_BENCH_NODE_FLAGS", ""), " ").

node_flags_text() ->
    case node_flags() of
        [] -> "default emulator flags on the server nodes";
        Flags -> "server node flags: " ++ lists:join(" ", Flags)
    end.

%% Stops a server's node without a shutdown. The server gets no chance to
%% close its storage. Returns when the controller has seen the node go down.
kill(C = #{peers := Peers}, {_Name, Node}) ->
    Peer = maps:get(Node, Peers),
    Ref = erlang:monitor(process, Peer),
    ok = net_kernel:monitor_nodes(true),
    ok = erpc:cast(Node, erlang, halt, [0, [{flush, false}]]),
    receive
        {nodedown, Node} -> ok
    after 10000 -> error(node_did_not_stop)
    end,
    ok = net_kernel:monitor_nodes(false),
    receive
        {'DOWN', Ref, process, Peer, _} -> ok
    after 10000 -> error(peer_did_not_stop)
    end,
    C#{peers := maps:remove(Node, Peers)}.

%% Starts the node of a killed server again, without the server.
boot(C = #{peers := Peers}, {_Name, Node}) ->
    [Name, _Host] = string:lexemes(atom_to_list(Node), "@"),
    {Node, Peer} = start_node(list_to_atom(Name)),
    C#{peers := Peers#{Node => Peer}}.

%% Starts a server on its node. Returns when the server has opened its
%% storage and recovered its state.
start_server(#{ids := Ids, opts := Opts}, Id = {_Name, Node}) ->
    ok = erpc:call(Node, peace, start_server, [Opts#{id => Id, members => Ids, machine => peace_kv:machine()}]).

await_leader(#{ids := Ids}) ->
    await_leader1(Ids, 2000).

await_leader1(_Ids, 0) ->
    error(no_leader);
await_leader1(Ids, N) ->
    case peace_kv:put(Ids, '$warm', 0, 1000) of
        {ok, ok, Leader} ->
            Leader;
        _ ->
            timer:sleep(5),
            [First | Rest] = Ids,
            await_leader1(Rest ++ [First], N - 1)
    end.

%% The overview of a server without the machine state. This function runs
%% on the server's node, so that the machine state is not sent to the
%% controller.
remote_overview(Id) ->
    case peace:overview(Id) of
        Overview when is_map(Overview) -> maps:remove(machine_state, Overview);
        Other -> Other
    end.

overview({_Name, Node} = Id) ->
    try
        erpc:call(Node, ?MODULE, remote_overview, [Id], 5000)
    catch
        _:_ -> #{}
    end.

commit_index(Id) ->
    maps:get(commit_index, overview(Id), 0).

%% Waits until the server has committed `Target'. Returns the time at which
%% it had, from `erlang:monotonic_time(microsecond)'.
await_commit(Id, Target) ->
    case commit_index(Id) >= Target of
        true ->
            now_us();
        false ->
            timer:sleep(1),
            await_commit(Id, Target)
    end.

%% ---------------------------------------------------------------------------
%% Load
%% ---------------------------------------------------------------------------

%% Runs closed-loop clients and prints one row. Each client sends one
%% request, waits for the answer, and sends the next request. A request is
%% counted if it started after the warm-up and was answered before the end
%% of the measurement.
run_load(Label, C, Spec0) ->
    Spec = maps:merge(
        #{op => put, value_bytes => ?VALUE_BYTES, warmup_ms => ?WARMUP_MS, measure_ms => ?MEASURE_MS}, Spec0
    ),
    #{clients := Clients, warmup_ms := Warmup, measure_ms := Measure} = Spec,
    #{ids := Ids} = C,
    Leader = await_leader(C),
    ok = prefill(Leader),
    StartAt = now_us() + Warmup * 1000,
    StopAt = StartAt + Measure * 1000,
    Parent = self(),
    Pids = [spawn_link(fun() -> client(Parent, Ids, Leader, Spec, StartAt, StopAt) end) || _ <- lists:seq(1, Clients)],
    Results = [
        receive
            {done, Pid, Lats, Errors} -> {Lats, Errors}
        end
     || Pid <- Pids
    ],
    Lats = lists:sort(lists:append([L || {L, _} <- Results])),
    Errors = lists:sum([E || {_, E} <- Results]),
    Count = length(Lats),
    row(load, [
        Label,
        integer_to_list(Clients),
        io_lib:format("~b", [round(Count * 1000 / Measure)]),
        ms(percentile(Lats, 0.50)),
        ms(percentile(Lats, 0.95)),
        ms(percentile(Lats, 0.99)),
        ms(percentile(Lats, 1.0)),
        integer_to_list(Errors)
    ]).

%% Stores a value under every key, so that every read finds a value.
prefill(Leader) ->
    Value = binary:copy(<<0>>, ?VALUE_BYTES),
    Parent = self(),
    Chunks = [lists:seq(I, ?KEYS, 20) || I <- lists:seq(1, 20)],
    Pids = [
        spawn_link(fun() ->
            [{ok, ok, _} = peace_kv:put(Leader, K, Value, 5000) || K <- Keys],
            Parent ! {filled, self()}
        end)
     || Keys <- Chunks
    ],
    [
        receive
            {filled, Pid} -> ok
        end
     || Pid <- Pids
    ],
    ok.

client(Parent, Ids, Leader, Spec = #{value_bytes := Bytes}, StartAt, StopAt) ->
    Value = crypto:strong_rand_bytes(Bytes),
    client_loop(Parent, Ids, Leader, Spec#{value => Value}, StartAt, StopAt, [], 0).

client_loop(Parent, Ids, Target, Spec = #{op := Op, value := Value}, StartAt, StopAt, Lats, Errors) ->
    T0 = now_us(),
    case T0 >= StopAt of
        true ->
            Parent ! {done, self(), Lats, Errors};
        false ->
            Key = rand:uniform(?KEYS),
            Result =
                case Op of
                    put -> peace_kv:put(Target, Key, Value, 5000);
                    get -> peace_kv:get(Target, Key, 5000);
                    read -> peace_kv:read(Target, Key, 5000);
                    stale_read -> peace_kv:stale_read(Target, Key, 5000)
                end,
            T1 = now_us(),
            case Result of
                {ok, _Reply, _Leader} when T0 >= StartAt, T1 =< StopAt ->
                    client_loop(Parent, Ids, Target, Spec, StartAt, StopAt, [T1 - T0 | Lats], Errors);
                {ok, _Reply, _Leader} ->
                    client_loop(Parent, Ids, Target, Spec, StartAt, StopAt, Lats, Errors);
                _ ->
                    client_loop(Parent, Ids, Target, Spec, StartAt, StopAt, Lats, Errors + 1)
            end
    end.

%% Proposes `Count' puts of `Bytes'-byte values from `Workers' processes.
%% Every put has a different key.
puts(Leader, Tag, Count, Bytes, Workers) ->
    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            Value = crypto:strong_rand_bytes(Bytes),
            [{ok, ok, _} = peace_kv:put(Leader, {Tag, K}, Value, 60000) || K <- lists:seq(W, Count, Workers)],
            Parent ! {put_done, self()}
        end)
     || W <- lists:seq(1, Workers)
    ],
    [
        receive
            {put_done, Pid} -> ok
        end
     || Pid <- Pids
    ],
    ok.

%% ---------------------------------------------------------------------------
%% Recovery
%% ---------------------------------------------------------------------------

%% Kills the leader's node `N' times. Returns, for each kill, the time in
%% microseconds from the kill to the first answered put that was sent after
%% the kill. The killed server is restarted and catches up before the next
%% kill.
failover_trials(_C, 0) ->
    [];
failover_trials(C0 = #{ids := Ids}, N) ->
    Leader = await_leader(C0),
    %% The followers must have heard from the leader, so that each follower
    %% has an election timer that the leader's heartbeat resets.
    timer:sleep(500),
    Rest = Ids -- [Leader],
    Killed = now_us(),
    C1 = kill(C0, Leader),
    Answered = first_put(Rest),
    C2 = boot(C1, Leader),
    ok = start_server(C2, Leader),
    NewLeader = await_leader(C2),
    _ = await_commit(Leader, commit_index(NewLeader)),
    [Answered - Killed | failover_trials(C2, N - 1)].

first_put(Ids = [First | Rest]) ->
    case peace_kv:put(Ids, '$probe', 0, 200) of
        {ok, ok, _} ->
            now_us();
        _ ->
            timer:sleep(1),
            first_put(Rest ++ [First])
    end.

%% Loads `MB' megabytes of machine state, kills a follower's node and
%% restarts the follower. No value is proposed while the follower is down.
restart_trial(C0 = #{ids := Ids}, Storage, MB) ->
    Leader = await_leader(C0),
    ok = puts(Leader, blob, MB * 16, 65536, 4),
    [Follower | _] = Ids -- [Leader],
    Target = commit_index(Leader),
    _ = await_commit(Follower, Target),
    #{snapshot_index := Snap} = overview(Follower),
    C1 = boot(kill(C0, Follower), Follower),
    T0 = now_us(),
    ok = start_server(C1, Follower),
    T1 = now_us(),
    T2 = await_commit(Follower, Target),
    row(restart, [
        atom_to_list(Storage),
        io_lib:format("~b MB", [MB]),
        integer_to_list(Target - Snap),
        ms(T1 - T0),
        ms(T2 - T0),
        file_mb(C1, Follower)
    ]),
    C1.

%% Kills a follower's node, proposes `Missed' values, and restarts the
%% follower. No value is proposed while the follower catches up.
catch_up_trial(C0 = #{ids := Ids}, HeartbeatMs, Missed) ->
    Leader = await_leader(C0),
    [Follower | _] = Ids -- [Leader],
    _ = await_commit(Follower, commit_index(Leader)),
    C1 = kill(C0, Follower),
    ok = puts(Leader, missed, Missed, 1000, 16),
    #{commit_index := Target, snapshot_index := Snap} = overview(Leader),
    C2 = boot(C1, Follower),
    T0 = now_us(),
    ok = start_server(C2, Follower),
    T1 = await_commit(Follower, Target),
    row(catch_up, [
        integer_to_list(HeartbeatMs),
        integer_to_list(Missed),
        case Snap >= Target - Missed of
            true -> "snapshot";
            false -> "log entries"
        end,
        ms(T1 - T0)
    ]),
    C2.

%% The size of the files of a server. The dets backend has one file. The
%% write-ahead log backend has one directory.
file_mb(#{dir := Dir}, {Name, Node}) ->
    Base = filename:join(Dir, lists:concat([Name, "@", Node])),
    Files = [Base ++ ".peace" | filelib:wildcard(filename:join(Base, "*"))],
    io_lib:format("~.1f", [lists:sum([filelib:file_size(F) || F <- Files]) / 1048576]).

%% ---------------------------------------------------------------------------
%% Output
%% ---------------------------------------------------------------------------

header(load) ->
    io:format("~n| Configuration | Clients | Requests/s | p50 ms | p95 ms | p99 ms | Max ms | Errors |~n", []),
    io:format("|---|---|---|---|---|---|---|---|~n", []);
header(failover) ->
    io:format("~n| Configuration | Trials | Min ms | Median ms | Max ms |~n|---|---|---|---|---|~n", []);
header(restart) ->
    io:format(
        "~n| Storage | Machine state | Log entries above the snapshot | Server start ms | Caught up ms | Files MB |~n"
        "|---|---|---|---|---|---|~n",
        []
    );
header(catch_up) ->
    io:format("~n| Heartbeat ms | Values missed | Transferred as | Caught up ms |~n|---|---|---|---|~n", []).

row(_Kind, Cells) ->
    io:format("| ~s |~n", [lists:join(" | ", [lists:flatten(io_lib:format("~s", [C])) || C <- Cells])]).

summary(Times) ->
    Sorted = lists:sort(Times),
    [integer_to_list(length(Sorted)), ms(hd(Sorted)), ms(percentile(Sorted, 0.5)), ms(lists:last(Sorted))].

now_us() ->
    erlang:monotonic_time(microsecond).

ms(Us) when Us < 10000 -> io_lib:format("~.2f", [Us / 1000]);
ms(Us) -> io_lib:format("~.1f", [Us / 1000]).

%% `Sorted' is in ascending order. Returns 0 for an empty list.
percentile([], _P) ->
    0;
percentile(Sorted, P) ->
    lists:nth(max(1, ceil(P * length(Sorted))), Sorted).
