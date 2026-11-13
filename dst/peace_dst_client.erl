%% This module contains the code of the operations of the simulation. The
%% scheduler steps this code.
%%
%% The functions run in processes spawned by `eta_run:spawn_op/1', so the
%% processes are part of the simulated system. The sleeps and the call
%% timeouts of the processes must use the virtual clock, and the calls of
%% the processes must go through the simulated network. This module is
%% therefore compiled with the eta transform. The harness module is not.
-module(peace_dst_client).

-include("peace_eta.hrl").

-export([value/5, pipeline/3, query/3, reconfigure/5, restart/1, deliver/3]).

%% The number of values that a client of `pipeline/3' submits, and the time
%% that the client waits for the replies.
-define(PIPELINE, 3).
-define(PIPELINE_MS, 600).

-define(CALL_TIMEOUT_MS, 200).
-define(RETRY_AFTER_MS, 60).
-define(ATTEMPTS, 4).

%% Submits one value and records the result that the client received. `Op'
%% is unique to this operation, so the harness can find the value in the
%% log.
%%
%% `Retry' selects what the client does when the outcome of the request is
%% unknown:
%%   - `session' submits the value again under the same session. This is
%%     the purpose of sessions.
%%   - `bare' submits the value again without a session. This is the
%%     mistake that sessions prevent.
%%   - `none' stops.
value(Tab, N, Servers, Op, Retry) ->
    ?ETA_LABEL({client, N}),
    true = ets:insert(Tab, {{op, Op}, invoked}),
    ok = history(Tab, {invoke, N, {append, Op}}),
    Opts =
        case Retry of
            session -> #{timeout => ?CALL_TIMEOUT_MS, session => {N, 1}};
            _ -> #{timeout => ?CALL_TIMEOUT_MS}
        end,
    Result = submit(fun() -> peace:propose(Servers, {put, Op}, Opts) end, ?ATTEMPTS, Retry =/= none),
    _ = ?ETA_LOG({client, N, Op, Result}),
    true = ets:insert(Tab, {{op, Op}, Result}),
    ok = history(Tab, {return, N, Result}),
    ok.

%% Submits three values through one session process and records the result
%% of each value. The three values are undecided at the same time. The
%% operation of value `K' is `{N, K}', so the harness can check the order in
%% which the values of one session were applied.
%%
%% The client stops waiting after `?PIPELINE_MS'. The outcome of a value
%% that has no reply at that time is unknown.
%%
%% The client does not close the session, and waits indefinitely after it
%% has recorded the results. The session process continues to submit the
%% values that have no reply, as a real client does. There is a second
%% reason. A server can send a reply after the client has stopped waiting.
%% The simulated network holds a delayed message on a timer. A timer for a
%% process that has exited fails the audit of the run. The harness kills the
%% client and the session process when the run ends.
pipeline(Tab, N, Servers) ->
    ?ETA_LABEL({client, N}),
    {ok, Session} = peace:open_session(Servers, #{id => N, window => ?PIPELINE, retry_ms => ?RETRY_AFTER_MS}),
    true = ets:insert(Tab, {{session, N}, Session}),
    Refs = [
        begin
            Op = {N, K},
            true = ets:insert(Tab, {{op, Op}, invoked}),
            ok = history(Tab, {invoke, Op, {append, Op}}),
            {Op, peace:cast(Session, {put, Op})}
        end
     || K <- lists:seq(1, ?PIPELINE)
    ],
    Deadline = erlang:send_after(?PIPELINE_MS, self(), pipeline_deadline),
    ok = collect(Tab, Refs),
    _ = erlang:cancel_timer(Deadline),
    true = ets:insert(Tab, {{pipeline_done, N}, true}),
    receive
        stop -> ok
    end.

collect(_Tab, []) ->
    ok;
collect(Tab, Refs) ->
    receive
        {peace_reply, Ref, Reply} ->
            {Op, Ref} = lists:keyfind(Ref, 2, Refs),
            Result =
                case Reply of
                    {ok, Index} -> {ok, Index};
                    Other -> {unknown, Other}
                end,
            ok = record(Tab, Op, Result),
            collect(Tab, lists:keydelete(Ref, 2, Refs));
        pipeline_deadline ->
            lists:foreach(fun({Op, _Ref}) -> ok = record(Tab, Op, {unknown, timeout}) end, Refs)
    end.

record(Tab, Op, Result) ->
    _ = ?ETA_LOG({client, Op, Result}),
    true = ets:insert(Tab, {{op, Op}, Result}),
    history(Tab, {return, Op, Result}).

%% Performs a linearizable read of every value applied so far. Records the
%% answer together with the values that had already been acknowledged when
%% the query was issued. The answer must contain all of those values.
query(Tab, N, Servers) ->
    ?ETA_LABEL({client, N}),
    Before = [Op || [Op] <- ets:match(Tab, {{op, '$1'}, {ok, '_'}})],
    ok = history(Tab, {invoke, N, read}),
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
    ok = history(Tab, {return, N, Result}),
    ok.

%% Records one event of the client history: the invocation of an operation,
%% or the result that the client received. The events are numbered in the
%% order in which they happened. One process runs at a time in a simulated
%% run, so this order is the real-time order of the events. See
%% `peace_dst_history'.
history(Tab, Event) ->
    Seq = ets:update_counter(Tab, history_seq, 1, {history_seq, 0}),
    true = ets:insert(Tab, {{history, Seq}, Event}),
    ok.

%% Requests a membership change. `submit/3' is called with `Again' false:
%%   - After `{error, no_leader}', `{error, noproc}' or
%%     `{error, overloaded}' the request was never submitted. The request is retried, for at most four attempts
%%     in total.
%%   - After any other answer, including a timeout, the request is not
%%     retried. The log shows whether the change happened, and the next
%%     request discovers the result.
reconfigure(Tab, N, Servers, Members, Quorum) ->
    ?ETA_LABEL({client, N}),
    Result = submit(fun() -> peace:change_members(Servers, Members, Quorum, ?CALL_TIMEOUT_MS) end, ?ATTEMPTS, false),
    _ = ?ETA_LOG({client, N, reconfigure, element(1, Result)}),
    true = ets:insert(Tab, {{reconfigure, N}, Result}),
    ok.

%% Restarts a killed server from inside the schedule. A start from the
%% driver would wait on a child process that the scheduler never releases.
%% This process links to the server and then waits indefinitely. The link
%% gives the server the one property that a supervisor provides here:
%% whatever kills this process also kills the server, even a server that has
%% not yet registered its name.
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

%% Always retries after an answer that means the request was never
%% submitted. After any other answer, including a timeout, the request may
%% have been submitted. Such a request is retried only if `Again' is true.
%% Otherwise the client stops and reports the outcome as unknown.
submit(Fun, Attempts, Again) ->
    case Fun() of
        {ok, Reply, _Leader} ->
            {ok, Reply};
        {error, Reason} when
            Attempts > 1, (Reason =:= no_leader orelse Reason =:= noproc orelse Reason =:= overloaded)
        ->
            _ = Reason =:= overloaded andalso peace_dst:bump(overloaded),
            timer:sleep(?RETRY_AFTER_MS),
            submit(Fun, Attempts - 1, Again);
        {error, Reason} when
            Reason =:= no_leader; Reason =:= noproc; Reason =:= too_many_redirects; Reason =:= overloaded
        ->
            {rejected, Reason};
        _Unknown when Again, Attempts > 1 ->
            timer:sleep(?RETRY_AFTER_MS),
            submit(Fun, Attempts - 1, Again);
        Other ->
            {unknown, Other}
    end.

%% Delivers a protocol message to a server as if `From' had sent the
%% message.
deliver(To, From, Msg) ->
    ?ETA_LABEL(rumour),
    _ = erlang:send(To, {peace_msg, From, Msg}, [noconnect]),
    ok.
