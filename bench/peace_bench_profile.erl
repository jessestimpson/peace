%% @doc Measurements of one process under load, for the benchmark harness.
%% The functions run on the node of the process. See "Overload" in
%% bench/README.md.
-module(peace_bench_profile).

-export([sample/2, calls/3]).

%% Observes the process `Pid' for `Ms' milliseconds. Returns a map:
%%
%% <ul>
%% <li>`samples' - the number of samples. The function reads the state of
%%   the process about once per millisecond.</li>
%% <li>`status' - the number of samples for each status of the
%%   process.</li>
%% <li>`functions' - the number of samples for each function at the top of
%%   the stack of the process.</li>
%% <li>`callers' - the number of samples for each function of
%%   `peace_server' that is nearest to the top of the stack.</li>
%% <li>`mailbox' - the smallest, the mean and the largest length of the
%%   mailbox in the samples.</li>
%% <li>`reductions', `minor_gcs' - the increase during the
%%   observation.</li>
%% <li>`msacc' - the time of the scheduler threads of the node in each
%%   state of microstate accounting, in microseconds.</li>
%% <li>`events' - the number of events of `erlang:system_monitor/2' for
%%   the process: `busy_dist_port', `busy_port', and garbage collections
%%   and schedules longer than 20 ms.</li>
%% <li>`processes' - the 8 processes of the node with the largest increase
%%   in reductions.</li>
%% </ul>
%%
%% The node answers a request for the state of a running process when the
%% process next yields. The samples of `functions' are therefore the
%% places where the process yields, and not a uniform sample of time.
-spec sample(pid(), pos_integer()) -> map().
sample(Pid, Ms) ->
    Old = erlang:system_monitor(self(), [busy_dist_port, busy_port, {long_gc, 20}, {long_schedule, 20}]),
    _ = erlang:system_flag(microstate_accounting, reset),
    _ = erlang:system_flag(microstate_accounting, true),
    Reductions0 = reductions(),
    {reductions, R0} = erlang:process_info(Pid, reductions),
    Gc0 = minor_gcs(Pid),
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    Samples = loop(Pid, Deadline, []),
    {reductions, R1} = erlang:process_info(Pid, reductions),
    Gc1 = minor_gcs(Pid),
    Msacc = erlang:statistics(microstate_accounting),
    _ = erlang:system_flag(microstate_accounting, false),
    Reductions1 = reductions(),
    _ =
        case Old of
            undefined -> erlang:system_monitor(undefined);
            _ -> erlang:system_monitor(Old)
        end,
    Lengths = [L || {_Status, _Stack, L} <- Samples],
    #{
        samples => length(Samples),
        status => tally([Status || {Status, _Stack, _L} <- Samples]),
        functions => tally([top(Stack) || {_Status, Stack, _L} <- Samples]),
        callers => tally([caller(Stack) || {_Status, Stack, _L} <- Samples]),
        mailbox => {lists:min(Lengths), lists:sum(Lengths) div length(Lengths), lists:max(Lengths)},
        reductions => R1 - R0,
        minor_gcs => Gc1 - Gc0,
        msacc => msacc(Msacc),
        events => tally(events(Pid, [])),
        processes => lists:sublist(
            lists:reverse(
                lists:sort([
                    {N - maps:get(P, Reductions0, 0), P, name(P)}
                 || {P, N} <- maps:to_list(Reductions1)
                ])
            ),
            8
        )
    }.

%% Profiles the calls of the process `Pid' for `Ms' milliseconds with
%% `eprof', and writes the analysis to the file `File'. Call tracing slows
%% the process, so the times are a division of the time of the process and
%% not a measurement of the load.
-spec calls(pid(), pos_integer(), file:filename()) -> ok.
calls(Pid, Ms, File) ->
    {ok, _} = eprof:start(),
    profiling = eprof:start_profiling([Pid]),
    timer:sleep(Ms),
    profiling_stopped = eprof:stop_profiling(),
    ok = eprof:log(File),
    _ = eprof:analyze(total, [{sort, time}]),
    stopped = eprof:stop(),
    ok.

loop(Pid, Deadline, Samples) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            Samples;
        false ->
            Sample =
                case erlang:process_info(Pid, [status, current_stacktrace, message_queue_len]) of
                    [{status, Status}, {current_stacktrace, Stack}, {message_queue_len, Length}] ->
                        {Status, Stack, Length};
                    undefined ->
                        {exited, [], 0}
                end,
            timer:sleep(1),
            loop(Pid, Deadline, [Sample | Samples])
    end.

top([{M, F, A, _Location} | _]) -> {M, F, A};
top([]) -> none.

caller([{peace_server, F, A, _Location} | _]) -> {peace_server, F, A};
caller([_ | Stack]) -> caller(Stack);
caller([]) -> none.

minor_gcs(Pid) ->
    {garbage_collection, Info} = erlang:process_info(Pid, garbage_collection),
    proplists:get_value(minor_gcs, Info).

reductions() ->
    maps:from_list([
        {P, N}
     || P <- erlang:processes(), {reductions, N} <- [erlang:process_info(P, reductions)]
    ]).

name(P) ->
    case erlang:process_info(P, [registered_name, initial_call, dictionary]) of
        [{registered_name, Name}, _, _] when is_atom(Name) ->
            Name;
        [_, {initial_call, Call}, {dictionary, Dictionary}] ->
            proplists:get_value('$initial_call', Dictionary, Call);
        undefined ->
            exited
    end.

%% The time of the scheduler threads in each state.
msacc(Threads) ->
    maps:to_list(
        lists:foldl(
            fun
                (#{type := scheduler, counters := Counters}, Acc) ->
                    maps:fold(
                        fun(State, Time, A) ->
                            Us = erlang:convert_time_unit(Time, perf_counter, microsecond),
                            maps:update_with(State, fun(T) -> T + Us end, Us, A)
                        end,
                        Acc,
                        Counters
                    );
                (_Thread, Acc) ->
                    Acc
            end,
            #{},
            Threads
        )
    ).

events(Pid, Events) ->
    receive
        {monitor, Pid, long_gc, _Info} -> events(Pid, [long_gc | Events]);
        {monitor, Pid, long_schedule, _Info} -> events(Pid, [long_schedule | Events]);
        {monitor, Pid, busy_dist_port, _Port} -> events(Pid, [busy_dist_port | Events]);
        {monitor, Pid, busy_port, _Port} -> events(Pid, [busy_port | Events]);
        {monitor, _Other, _Tag, _Info} -> events(Pid, Events)
    after 0 ->
        Events
    end.

tally(List) ->
    lists:reverse(
        lists:keysort(2, maps:to_list(lists:foldl(fun(K, A) -> maps:update_with(K, fun(N) -> N + 1 end, 1, A) end, #{}, List)))
    ).
