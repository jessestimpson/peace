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

-export([value/5, pipeline/3, query/3, reconfigure/5, restart/1, deliver/6, form/3, form/4, activate/1]).

%% The number of values that a client of `pipeline/3' submits, and the time
%% that the client waits for the replies.
-define(PIPELINE, 3).
-define(PIPELINE_MS, 600).

-define(CALL_TIMEOUT_MS, 200).
-define(RETRY_AFTER_MS, 60).
-define(ATTEMPTS, 4).

%% The timeout of a call of `form/3', and the time between two attempts.
-define(FORM_TIMEOUT_MS, 25).
-define(FORM_RETRY_MS, 10).

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

%% Delivers a protocol message to the server at the address `To', as if
%% the member `From' had sent the message to the member `Receiver'.
%% `FromRange' and `ToRange' are the ranges of message versions of the two
%% servers.
deliver(To, From, Receiver, Msg, FromRange, ToRange) ->
    ?ETA_LABEL(rumour),
    Version = peace_wire:choose(FromRange, ToRange),
    _ = erlang:send(To, {peace_msg, Version, FromRange, From, Receiver, peace_wire:encode(Version, Msg)}, [noconnect]),
    ok.

%% Activates a passive server. See `peace:activate/2'.
activate(Id) ->
    ?ETA_LABEL(activator),
    _ = call(Id, activate, ?CALL_TIMEOUT_MS),
    ok.

%% Forms the cluster of the founders. The client asks every founder for its
%% incarnation and then stores the configuration on every founder.
%%
%% A run lasts less than one second of simulated time, and a cluster that
%% forms late decides few values. The client is therefore more persistent
%% than `peace:form_cluster/3':
%%
%% <ul>
%% <li>A call has a timeout of 25 ms, so that a lost message costs little
%%   time.</li>
%% <li>The client keeps the incarnation that a founder reported in an
%%   earlier attempt. A founder that is killed and restarted recovers its
%%   incarnation from its disk.</li>
%% <li>The client stores the configuration on the founders that answer, and
%%   repeats the attempt until every founder has stored it, for at most
%%   `Attempts' attempts.</li>
%% <li>The client asks the first founder that stores the configuration to
%%   campaign.</li>
%% </ul>
%%
%% The client stops if a founder has another configuration, as
%% `peace:form_cluster/3' does. A founder that lost its disk after some
%% founders stored the configuration has a new incarnation. A second
%% configuration with that incarnation would form a second cluster.
%%
%% The client calls the servers directly, and not `peace:form_cluster/3',
%% so that a run can form a cluster with an unsafe quorum system. See the
%% `unsafe_quorums' mode of `peace_dst'.
form(Founders, Quorum, Attempts) ->
    form(Founders, Quorum, Attempts, false).

%% `Seeded' selects a formation with a machine state. See "Formation with a
%% machine state" in `peace_core'.
%%
%% <ul>
%% <li>`false' - every founder stores the configuration.</li>
%% <li>`{all, MState}' - every founder stores the configuration and the
%%   machine state.</li>
%% <li>`{first, MState}' - only the first founder stores the configuration
%%   and the machine state. The other founders have no configuration. They
%%   receive the configuration and the machine state from the leader.</li>
%% </ul>
form(Founders, Quorum, Attempts, Seeded) ->
    ?ETA_LABEL(former),
    put(seeded, Seeded),
    form(Founders, Quorum, Attempts, #{}, false).

form(_Founders, _Quorum, 0, _Known, _Asked) ->
    ok;
form(Founders, Quorum, Attempts, Known0, Asked0) ->
    {Targets, Request} =
        case get(seeded) of
            false -> {Founders, fun(Config) -> {form, Config} end};
            {all, MState} -> {Founders, fun(Config) -> {form, Config, {machine_state, MState}} end};
            {first, MState} -> {[hd(Founders)], fun(Config) -> {form, Config, {machine_state, MState}} end}
        end,
    Answers = [{Id, call(Id, identity, ?FORM_TIMEOUT_MS)} || Id <- Founders],
    Known = maps:merge(Known0, maps:from_list([{Id, Member} || {Id, {ok, Member, _Config}} <- Answers])),
    New = {lists:usort(maps:values(Known)), to_members(Quorum, Known)},
    Other = [Config || {_Id, {ok, _Member, Config}} <- Answers, Config =/= none, Config =/= {final, New}],
    case {Other, map_size(Known) =:= length(Founders)} of
        {[_ | _], _} ->
            _ = ?ETA_LOG({former, stopped}),
            ok;
        {[], true} ->
            %% Every founder is asked, also after one has not answered.
            Stored = [{Id, call(Id, Request(New), ?FORM_TIMEOUT_MS)} || Id <- Targets],
            %% The first election does not wait for an election timeout, so
            %% that the cluster has a leader before the faults of the run
            %% stop a phase-one quorum. The client asks once, the first
            %% founder that has stored the configuration.
            Asked =
                case {Asked0, [Id || {Id, ok} <- Stored]} of
                    {false, [First | _]} ->
                        ok = peace:trigger_election(First),
                        true;
                    _ ->
                        Asked0
                end,
            case lists:usort([Result || {_Id, Result} <- Stored]) of
                [ok] ->
                    _ = ?ETA_LOG({former, formed}),
                    ok;
                _ ->
                    timer:sleep(?FORM_RETRY_MS),
                    form(Founders, Quorum, Attempts - 1, Known, Asked)
            end;
        {[], false} ->
            timer:sleep(?FORM_RETRY_MS),
            form(Founders, Quorum, Attempts - 1, Known, Asked0)
    end.

%% A grid is given with addresses. The configuration names members.
to_members({grid, Rows}, Known) ->
    {grid, [[maps:get(Id, Known, Id) || Id <- Row] || Row <- Rows]};
to_members(Quorum, _Known) ->
    Quorum.

call(Id, Request, Timeout) ->
    try
        gen_server:call(Id, Request, Timeout)
    catch
        exit:_ -> {error, down}
    end.
