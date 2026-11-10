%% What the simulation's operations do, as code the scheduler steps.
%%
%% These run in processes spawned by `eta_run:spawn_op/1', which makes them
%% part of the system: their sleeps and call timeouts have to be on the
%% virtual clock and their calls routed through the simulated network, so
%% this module takes the transform. The harness itself does not.
-module(peace_dst_client).

-include("peace_eta.hrl").

-export([value/5, query/3, reconfigure/5, restart/1, deliver/3]).

-define(CALL_TIMEOUT_MS, 200).
-define(RETRY_AFTER_MS, 60).
-define(ATTEMPTS, 4).

%% Submits one value and records what the client was told. `Op' is unique
%% to this operation, so the harness can find the value in the log.
%%
%% `Retry' is what the client does when it cannot tell what happened:
%% `session' submits again under the same session, which is what sessions
%% are for; `bare' submits again without one, which is the mistake they
%% prevent; `none' gives up.
value(Tab, N, Servers, Op, Retry) ->
    ?ETA_LABEL({client, N}),
    true = ets:insert(Tab, {{op, Op}, invoked}),
    Opts =
        case Retry of
            session -> #{timeout => ?CALL_TIMEOUT_MS, session => {N, 1}};
            _ -> #{timeout => ?CALL_TIMEOUT_MS}
        end,
    Result = submit(fun() -> peace:process_value(Servers, {put, Op}, Opts) end, ?ATTEMPTS, Retry =/= none),
    _ = ?ETA_LOG({client, N, Op, Result}),
    true = ets:insert(Tab, {{op, Op}, Result}),
    ok.

%% A linearizable read of every value applied so far. Records, with the
%% answer, which values had already been acknowledged when it asked: all of
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
        ?ATTEMPTS,
        false
    ),
    _ = ?ETA_LOG({client, N, query, element(1, Result)}),
    true = ets:insert(Tab, {{query, N}, lists:sort(Before), Result}),
    ok.

%% Asks for a change of membership. Not retried: whether it happened is in
%% the log, and the next request finds out.
reconfigure(Tab, N, Servers, Members, Quorum) ->
    ?ETA_LABEL({client, N}),
    Result = submit(fun() -> peace:change_members(Servers, Members, Quorum, ?CALL_TIMEOUT_MS) end, ?ATTEMPTS, false),
    _ = ?ETA_LOG({client, N, reconfigure, element(1, Result)}),
    true = ets:insert(Tab, {{reconfigure, N}, Result}),
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

%% Always retries the answers that mean the request was never submitted.
%% Anything else, a timeout included, may have been, and is retried only if
%% `Again': otherwise the client stops and reports the outcome as unknown.
submit(Fun, Attempts, Again) ->
    case Fun() of
        {ok, Reply, _Leader} ->
            {ok, Reply};
        {error, Reason} when Attempts > 1, (Reason =:= no_leader orelse Reason =:= noproc) ->
            timer:sleep(?RETRY_AFTER_MS),
            submit(Fun, Attempts - 1, Again);
        {error, Reason} when Reason =:= no_leader; Reason =:= noproc; Reason =:= too_many_redirects ->
            {rejected, Reason};
        _Unknown when Again, Attempts > 1 ->
            timer:sleep(?RETRY_AFTER_MS),
            submit(Fun, Attempts - 1, Again);
        Other ->
            {unknown, Other}
    end.

%% Hands a server a protocol message as if `From' had sent it.
deliver(To, From, Msg) ->
    ?ETA_LABEL(rumour),
    _ = erlang:send(To, {peace_msg, From, Msg}, [noconnect]),
    ok.
