%% @doc A client process that submits values under one session.
%%
%% Sessions are not in the thesis. See "Sessions" in `peace_core' for the
%% rules that the servers apply.
%%
%% A session process:
%%
%% <ul>
%% <li>gives each value the next sequence number of the session,</li>
%% <li>has up to `window' values undecided at the same time,</li>
%% <li>finds the leader, and</li>
%% <li>submits a value again until the value has a reply.</li>
%% </ul>
%%
%% The values of one session process are applied in the order in which the
%% session process received them. Each value is applied at most once.
%%
%% Use `peace:open_session/2', `peace:call/3', `peace:cast/2' and
%% `peace:close_session/1'.
%%
%% == Requests and replies ==
%%
%% The session process sends each value to one server, the target, in a
%% cast. The cast carries a label, `{Incarnation, Round, Seq}'. The server
%% sends the reply to the value, with the label, to the session process.
%%
%% A round is one attempt to submit every value that has no reply. The
%% session process sends the values of a round to one target, in the order
%% of the sequence numbers. A value that is submitted during a round is sent
%% to the same target.
%%
%% The session process starts a new round when:
%%
%% <ul>
%% <li>a reply of the current round is `{error, {session_gap, Last}}'. A
%%   value with a lower sequence number was lost.</li>
%% <li>a reply of the current round is `{error, {not_leader, Leader}}' and
%%   names a leader. The leader is the new target. The session process
%%   follows at most 3 such replies in one retry time.</li>
%% <li>a reply of the current round is another error, such as
%%   `{error, overloaded}' or `{error, leadership_lost}'. The new round
%%   starts after a delay. See "Overload".</li>
%% <li>no value received a reply for `retry_ms'. The next server in the list
%%   is the new target.</li>
%% </ul>
%%
%% An error reply of an earlier round is ignored. An `ok' reply is used
%% whatever its round is.
%%
%% == Overload ==
%%
%% A leader that is overloaded answers `{error, overloaded}'. A session
%% process that submitted the refused values again at once, or after a
%% fixed time, would add load to the leader, and many session processes
%% would do so at the same moment. The session process therefore does two
%% things.
%%
%% The delay before the new round is random. The delay is between `D / 2'
%% and `D'. `D' is 50 ms after the first error, and doubles with each
%% further error until a value receives a reply. `D' is at most `retry_ms'.
%%
%% The session process limits the number of values that it has sent and
%% that have no reply. The limit starts at `window'. The first
%% `{error, overloaded}' of a round halves the limit. Each reply to a value
%% adds 1 to the limit, up to `window'. The limit is at least 1. A value
%% above the limit has a sequence number and is not sent. This is the
%% method of TCP congestion avoidance (additive increase, multiplicative
%% decrease).
%%
%% == Eviction ==
%%
%% A cluster remembers `max_sessions' sessions. When the cluster evicts the
%% session, the servers answer `{error, {session_gap, 0}}'. The session
%% process then:
%%
%% <ol>
%% <li>answers every value that has a sequence number and no reply with
%%   `{error, session_evicted}'. Each of these values was applied once or
%%   was not applied.</li>
%% <li>continues under a new client id, with sequence number 1.</li>
%% </ol>
%%
%% The session process learns of the eviction from the reply to a value. A
%% session that was evicted while it had no value undecided therefore
%% answers its next value with `{error, session_evicted}'.
%%
%% == Limitations ==
%%
%% <ul>
%% <li>A value that has a sequence number cannot be withdrawn. The session
%%   process submits the value until the value has a reply. The values
%%   behind it wait. A call that times out leaves its value in the
%%   session.</li>
%% <li>The session does not survive the session process. A new session
%%   process must use an id that no earlier session process used.</li>
%% <li>`window' must be at most the `session_window' of the cluster. With a
%%   larger `window', a value that was applied can be answered
%%   `{error, {session_superseded, Last}}' instead of its reply.</li>
%% <li>A copy of a value can be decided after the cluster evicted the
%%   session. The servers then have no record of the session. A copy with
%%   sequence number 1 is applied again, and after it a copy with sequence
%%   number 2, and so on. A copy that does not continue this sequence is
%%   refused.</li>
%% </ul>
-module(peace_session).

-behaviour(gen_server).

-include("peace.hrl").
-include("peace_eta.hrl").

-export([start_link/2, stop/1, call/3, cast/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([opts/0, result/0]).

-type opts() :: #{
    %% The number of values that the session has undecided at one time. The
    %% default is 64.
    window => pos_integer(),
    %% The session process changes to the next server when no value
    %% received a reply for this time. The default is 1000.
    retry_ms => pos_integer(),
    %% The id of the session. No other session, and no earlier session
    %% process, may use the same id. The default is a term that is unique.
    id => term()
}.

-type result() :: {ok, Reply :: term()} | {error, term()}.

%% The longest time before a new round after the first error reply. See
%% "Overload".
-define(BACKOFF_MS, 50).
%% The number of `not_leader' replies that are followed in one retry time.
-define(MAX_HOPS, 3).

%% In a simulated run, this macro counts an occurrence for the statistics of
%% the simulation.
-ifdef(DST).
%% The macro writes to the table of `peace_dst' if the table exists, and
%% does not call `peace_dst'. Another application can then run peace under
%% eta without the harness of peace.
-define(COUNT(Key),
    case ets:whereis(peace_dst_stats) of
        undefined -> ok;
        _ -> _ = ets:update_counter(peace_dst_stats, Key, 1, {Key, 0}), ok
    end
).
-else.
-define(COUNT(Key), ok).
-endif.

-record(state, {
    servers :: [peace:server_id()],
    target :: peace:server_id(),
    id :: term(),
    %% The client id that the servers see is `{Id, Incarnation}'.
    incarnation = 0 :: non_neg_integer(),
    window :: pos_integer(),
    retry_ms :: pos_integer(),
    %% The next sequence number.
    next = 1 :: pos_integer(),
    %% The lowest sequence number that has no reply. `Low =:= Next' when
    %% every value has a reply.
    low = 1 :: pos_integer(),
    %% The values that have a sequence number and no reply.
    pending = #{} :: #{pos_integer() => {peace_machine:value(), reply_to()}},
    %% The values that wait for a sequence number, oldest first. A value
    %% waits while `window' values have no reply.
    waiting = queue:new() :: queue:queue({peace_machine:value(), reply_to(), gen_server:from() | undefined}),
    round = 0 :: non_neg_integer(),
    %% The value of `low' when the current round started.
    round_low = 1 :: pos_integer(),
    %% The timer that starts the next round, if one is set.
    resend :: reference() | undefined,
    %% The timer of the retry time. The timer runs while a value has no
    %% reply.
    tick :: reference() | undefined,
    %% Whether a value received a reply in the current retry time.
    progress = false :: boolean(),
    hops = 0 :: non_neg_integer(),
    %% The number of values that may be sent and have no reply. See
    %% "Overload".
    limit :: pos_integer(),
    %% The highest sequence number that was sent in the current round.
    sent = 0 :: non_neg_integer(),
    %% The number of error replies that started a delay since a value last
    %% received a reply.
    errors = 0 :: non_neg_integer()
}).

-type reply_to() :: {call, gen_server:from()} | {cast, pid(), reference()}.

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-spec start_link([peace:server_id()], opts()) -> {ok, pid()} | {error, term()}.
start_link(Servers = [_ | _], Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, {Servers, Opts}, []).

-spec stop(pid()) -> ok.
stop(Session) ->
    gen_server:stop(Session).

%% @doc Submits a value and waits for the reply. After `{timeout, Session}'
%% the value is still in the session.
-spec call(pid(), peace_machine:value(), timeout()) -> result() | {timeout, pid()}.
call(Session, Value, Timeout) ->
    try
        gen_server:call(Session, {call, Value}, Timeout)
    catch
        exit:{timeout, _} -> {timeout, Session};
        exit:{_Reason, _} -> {error, session_closed}
    end.

%% @doc Submits a value. Returns when the value has a sequence number. The
%% calling process receives `{peace_reply, Ref, Result}'.
-spec cast(pid(), peace_machine:value()) -> reference().
cast(Session, Value) ->
    Ref = make_ref(),
    try
        ok = gen_server:call(Session, {cast, self(), Ref, Value}, infinity)
    catch
        exit:{_Reason, _} -> self() ! {peace_reply, Ref, {error, session_closed}}
    end,
    Ref.

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

init({Servers, Opts}) ->
    process_flag(trap_exit, true),
    Id =
        case Opts of
            #{id := Given} -> Given;
            _ -> {node(), erlang:system_time(), erlang:unique_integer()}
        end,
    {ok, #state{
        servers = Servers,
        target = hd(Servers),
        id = Id,
        window = maps:get(window, Opts, ?DEFAULT_SESSION_WINDOW),
        limit = maps:get(window, Opts, ?DEFAULT_SESSION_WINDOW),
        retry_ms = maps:get(retry_ms, Opts, ?DEFAULT_ELECTION_TIMEOUT_MS)
    }}.

handle_call({call, Value}, From, State) ->
    {noreply, admit(enqueue({Value, {call, From}, undefined}, State))};
handle_call({cast, Pid, Ref, Value}, From, State) ->
    {noreply, admit(enqueue({Value, {cast, Pid, Ref}, From}, State))};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Other, State) ->
    {noreply, State}.

handle_info({peace_session_reply, {Incarnation, Round, Seq}, Result}, State = #state{incarnation = Incarnation}) ->
    case is_map_key(Seq, State#state.pending) of
        true -> {noreply, reply(Seq, Round, Result, State)};
        false -> {noreply, State}
    end;
handle_info({timeout, Ref, resend}, State = #state{resend = Ref}) ->
    {noreply, new_round(State#state{resend = undefined})};
handle_info({timeout, Ref, tick}, State = #state{tick = Ref, pending = Pending}) when map_size(Pending) =:= 0 ->
    {noreply, State#state{tick = undefined, progress = false, hops = 0}};
handle_info({timeout, Ref, tick}, State = #state{tick = Ref, progress = true}) ->
    {noreply, start_tick(State#state{progress = false, hops = 0})};
handle_info({timeout, Ref, tick}, State = #state{tick = Ref, servers = Servers, target = Target}) ->
    %% No value received a reply in the retry time.
    {noreply, new_round(start_tick(State#state{target = next(Target, Servers), hops = 0}))};
handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, State = #state{pending = Pending, waiting = Waiting, tick = Tick}) ->
    _ = cancel_resend(State),
    _ = Tick =/= undefined andalso erlang:cancel_timer(Tick),
    Closed = {error, session_closed},
    _ = [deliver(ReplyTo, Closed) || {_Value, ReplyTo} <- maps:values(Pending)],
    _ = [
        begin
            _ = Admission =/= undefined andalso gen_server:reply(Admission, ok),
            deliver(ReplyTo, Closed)
        end
     || {_Value, ReplyTo, Admission} <- queue:to_list(Waiting)
    ],
    ok.

%% ---------------------------------------------------------------------------
%% Submission
%% ---------------------------------------------------------------------------

enqueue(Item, State = #state{waiting = Waiting}) ->
    State#state{waiting = queue:in(Item, Waiting)}.

%% Gives a sequence number to each waiting value, oldest first, while fewer
%% than `window' values have no reply.
admit(State = #state{next = Next, low = Low, window = Window, waiting = Waiting, pending = Pending}) when
    Next - Low < Window
->
    case queue:out(Waiting) of
        {{value, {Value, ReplyTo, Admission}}, Rest} ->
            _ = Admission =/= undefined andalso gen_server:reply(Admission, ok),
            State1 = State#state{next = Next + 1, pending = Pending#{Next => {Value, ReplyTo}}, waiting = Rest},
            admit(ensure_tick(State1));
        {empty, _} ->
            pump(State)
    end;
admit(State) ->
    pump(State).

%% Sends the values that are inside the limit and that were not sent in the
%% current round, in the order of the sequence numbers. No value is sent
%% while a new round is about to start. The new round sends the values.
pump(State = #state{resend = undefined, sent = Sent, low = Low, next = Next, limit = Limit, pending = Pending}) ->
    Last = min(Next - 1, Low + Limit - 1),
    _ = [send(Seq, State) || Seq <- lists:seq(max(Sent + 1, Low), Last, 1), is_map_key(Seq, Pending)],
    State#state{sent = max(Sent, Last)};
pump(State) ->
    State.

send(Seq, #state{target = Target, id = Id, incarnation = Incarnation, round = Round, pending = Pending}) ->
    #{Seq := {Value, _ReplyTo}} = Pending,
    From = {peace_session, self(), {Incarnation, Round, Seq}},
    gen_server:cast(Target, {value, From, Value, {{Id, Incarnation}, Seq}}).

%% Starts a round. Sends the values that have no reply and that are inside
%% the limit, in the order of the sequence numbers.
new_round(State0 = #state{round = Round, low = Low, pending = Pending}) ->
    State = cancel_resend(State0#state{round = Round + 1, round_low = Low, sent = Low - 1}),
    _ = map_size(Pending) > 0 andalso ?COUNT(session_rounds),
    pump(State).

%% Starts the delay before a new round, after an error reply. See
%% "Overload".
backoff(State = #state{resend = undefined, errors = Errors, retry_ms = RetryMs}) ->
    Longest = min(RetryMs, ?BACKOFF_MS bsl min(Errors, 16)),
    Half = Longest div 2,
    schedule_resend(Half + rand:uniform(Longest - Half + 1) - 1, State#state{errors = Errors + 1});
backoff(State) ->
    State.

schedule_resend(Ms, State = #state{resend = undefined}) ->
    State#state{resend = erlang:start_timer(Ms, self(), resend)};
schedule_resend(_Ms, State) ->
    State.

cancel_resend(State = #state{resend = undefined}) ->
    State;
cancel_resend(State = #state{resend = Ref}) ->
    _ = erlang:cancel_timer(Ref),
    State#state{resend = undefined}.

ensure_tick(State = #state{tick = undefined}) -> start_tick(State);
ensure_tick(State) -> State.

start_tick(State = #state{retry_ms = Ms}) ->
    State#state{tick = erlang:start_timer(Ms, self(), tick)}.

next(Target, Servers) ->
    case lists:dropwhile(fun(Server) -> Server =/= Target end, Servers) of
        [Target, Next | _] -> Next;
        _ -> hd(Servers)
    end.

%% ---------------------------------------------------------------------------
%% Replies
%% ---------------------------------------------------------------------------

%% `Seq' has no reply yet.
reply(Seq, _Round, {ok, Reply, _Leader}, State) ->
    admit(complete(Seq, {ok, Reply}, State));
reply(Seq, _Round, {error, {session_superseded, _Last}} = Applied, State) ->
    %% The value was applied. The servers no longer hold the reply.
    admit(complete(Seq, Applied, State));
reply(_Seq, Round, _Error, State = #state{round = Current}) when Round =/= Current ->
    State;
reply(_Seq, _Round, {error, {session_gap, Last}}, State = #state{round_low = Low}) when Last < Low - 1 ->
    %% Every value below `Low' was applied before this round started. A
    %% server that holds the session therefore answers with a `Last' of at
    %% least `Low - 1'. The session was evicted.
    admit(evicted(State));
reply(_Seq, _Round, {error, {session_gap, _Last}}, State) ->
    _ = ?COUNT(session_gaps),
    schedule_resend(0, State);
reply(_Seq, _Round, {error, {not_leader, Leader}}, State = #state{target = Target, hops = Hops}) when
    Leader =/= undefined, Leader =/= Target, Hops < ?MAX_HOPS
->
    schedule_resend(0, State#state{target = Leader, hops = Hops + 1});
reply(_Seq, _Round, {error, {not_leader, _Leader}}, State) ->
    %% The retry time selects the next server.
    State;
reply(_Seq, _Round, {error, overloaded}, State = #state{resend = undefined, limit = Limit}) ->
    _ = ?COUNT(session_overloaded),
    backoff(State#state{limit = max(1, Limit div 2)});
reply(_Seq, _Round, {error, _Reason}, State) ->
    backoff(State).

complete(Seq, Result, State = #state{pending = Pending0, low = Low0, next = Next}) ->
    {{_Value, ReplyTo}, Pending} = maps:take(Seq, Pending0),
    deliver(ReplyTo, Result),
    #state{limit = Limit, window = Window} = State,
    State#state{
        pending = Pending,
        low = low(Low0, Next, Pending),
        progress = true,
        errors = 0,
        limit = min(Window, Limit + 1)
    }.

low(Low, Next, Pending) when Low < Next, not is_map_key(Low, Pending) ->
    low(Low + 1, Next, Pending);
low(Low, _Next, _Pending) ->
    Low.

evicted(State = #state{pending = Pending, incarnation = Incarnation, round = Round}) ->
    _ = [deliver(ReplyTo, {error, session_evicted}) || {_Value, ReplyTo} <- maps:values(Pending)],
    cancel_resend(State#state{
        pending = #{},
        incarnation = Incarnation + 1,
        next = 1,
        low = 1,
        round = Round + 1,
        round_low = 1,
        sent = 0
    }).

deliver({call, From}, Result) ->
    gen_server:reply(From, Result),
    ok;
deliver({cast, Pid, Ref}, Result) ->
    Pid ! {peace_reply, Ref, Result},
    ok.
