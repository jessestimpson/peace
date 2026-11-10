%% What the simulation's operations do, as code the scheduler steps.
%%
%% These run in processes spawned by `eta_run:spawn_op/1', which makes them
%% part of the system: their sleeps and call timeouts have to be on the
%% virtual clock and their calls routed through the simulated network, so
%% this module takes the transform. The harness itself does not.
-module(peace_dst_client).

-include("peace_eta.hrl").

-export([command/4, query/3, restart/1]).

-define(CALL_TIMEOUT_MS, 200).
-define(RETRY_AFTER_MS, 60).
-define(ATTEMPTS, 4).

%% Submits one command and records what the client was told. `Op' is unique
%% to this operation, so the harness can find the command in the log.
command(Tab, N, Servers, Op) ->
    ?ETA_LABEL({client, N}),
    true = ets:insert(Tab, {{op, Op}, invoked}),
    Result = submit(fun() -> peace:process_command(Servers, {put, Op}, ?CALL_TIMEOUT_MS) end, ?ATTEMPTS),
    _ = ?ETA_LOG({client, N, Op, Result}),
    true = ets:insert(Tab, {{op, Op}, Result}),
    ok.

%% A linearizable read of every command applied so far. Records, with the
%% answer, which commands had already been acknowledged when it asked: all of
%% them have to be in it.
query(Tab, N, Servers) ->
    ?ETA_LABEL({client, N}),
    Before = [Op || [Op] <- ets:match(Tab, {{op, '$1'}, {ok, '_'}})],
    Result = submit(
        fun() ->
            peace:consistent_query(
                Servers, fun(History) -> [Op || {_I, {put, Op}} <- History] end, ?CALL_TIMEOUT_MS
            )
        end,
        ?ATTEMPTS
    ),
    _ = ?ETA_LOG({client, N, query, element(1, Result)}),
    true = ets:insert(Tab, {{query, N}, lists:sort(Before), Result}),
    ok.

%% Brings a killed server back, from inside the schedule: a start from the
%% driver would wait on a child the scheduler never releases. Linked, and
%% then parked for good, so that the server has the one thing a supervisor
%% gives it here: whatever kills this process takes the server with it, even
%% a server that has not got as far as registering its name.
restart(Config) ->
    ?ETA_LABEL(restarter),
    case peace_server:start_link(Config) of
        {ok, _Pid} ->
            receive
                stop -> ok
            end;
        {error, _Reason} ->
            ok
    end.

%% Retries only the answers that mean the request was never submitted.
%% Anything else, a timeout included, may have been: the client stops and
%% reports the outcome as unknown.
submit(Fun, Attempts) ->
    case Fun() of
        {ok, Reply, _Leader} ->
            {ok, Reply};
        {error, Reason} when Attempts > 1, (Reason =:= no_leader orelse Reason =:= noproc) ->
            timer:sleep(?RETRY_AFTER_MS),
            submit(Fun, Attempts - 1);
        {error, Reason} when Reason =:= no_leader; Reason =:= noproc; Reason =:= too_many_redirects ->
            {rejected, Reason};
        Other ->
            {unknown, Other}
    end.
