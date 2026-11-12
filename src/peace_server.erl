%% @doc One member of a peace cluster. This module is the process that runs
%% `peace_core'.
%%
%% `peace_core' computes the effects. This module performs them. This
%% module:
%%
%% <ul>
%% <li>owns the storage handle, the timers and the mailbox,</li>
%% <li>converts calls, casts and timeouts into `peace_core' events, and</li>
%% <li>performs the effects that `peace_core' returns.</li>
%% </ul>
%%
%% The important rule in this module is about ordering. This module writes
%% everything that `peace_core' asked to persist before it sends anything
%% that `peace_core' asked to send. Paxos does not tolerate the failure in
%% which a promise or an acceptance reaches a peer and is then lost in a
%% restart.
-module(peace_server).

-behaviour(gen_server).

-include("peace.hrl").
-include("peace_eta.hrl").
-eta_observe({state, [core]}).

-export([start_link/1, start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([step/0]).

%% In a simulated run, this macro writes one line to the run's log for each
%% event that this server handles.
-ifdef(DST).
-define(TRACE(Event, Core),
    ?ETA_LOG({peace, peace_core:id(Core), log_event(Event), peace_core:role(Core)})
).
log_event({msg, Peer, Msg}) -> {msg, Peer, element(1, Msg)};
log_event({value, _From, _Value}) -> value;
log_event({value, _From, _Value, _Session}) -> value;
log_event({query, _From, _Fun}) -> query;
log_event({reconfigure, _From, _New}) -> reconfigure;
log_event(Event) -> Event.
-else.
-define(TRACE(Event, Core), ok).
-endif.

-record(state, {
    core :: peace_core:core(),
    %% The rate of this server's clock, as a fraction. See `clock_rate/1'.
    clock = {1, 1} :: {pos_integer(), pos_integer()},
    storage_mod :: module(),
    storage :: term(),
    election_ms :: pos_integer(),
    heartbeat_ms :: pos_integer(),
    timers = #{} :: #{election | heartbeat => reference()},
    %% The nodes to which a connection attempt is in progress. See `send/3'.
    connecting = #{} :: #{node() => reference()},
    %% A function that is called with every step of `peace_core'. It is set
    %% only in a test build. See `tracer/1'.
    tracer :: undefined | fun((step()) -> term())
}).

%% One step of `peace_core', for trace validation against the TLA+ model.
%% A step contains:
%%   - the id of the server,
%%   - the event (`init' on start),
%%   - the core state before the event (`undefined' on start),
%%   - the core state after the event, and
%%   - the effects. All of the effects have been performed.
-type step() ::
    {peace:server_id(), init | peace_core:event(), undefined | peace_core:core(), peace_core:core(), [
        peace_core:effect()
    ]}.

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-spec start_link(peace:server_config()) -> {ok, pid()} | {error, term()}.
start_link(Config = #{id := {Name, _Node}}) ->
    gen_server:start_link({local, Name}, ?MODULE, Config, []).

%% @doc Starts a server without a link to the caller. This function is for
%% callers that are not supervisors.
-spec start(peace:server_config()) -> {ok, pid()} | {error, term()}.
start(Config = #{id := {Name, _Node}}) ->
    gen_server:start({local, Name}, ?MODULE, Config, []).

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

init(Config = #{id := Id, members := Members}) ->
    ?ETA_LABEL(Id),
    case check_quorum(Config, Members) of
        ok ->
            {StorageMod, StorageArgs} = maps:get(storage, Config, {peace_storage_mem, #{}}),
            {ok, Storage, Stored} = peace_storage:open(StorageMod, Id, StorageArgs),
            Clock = clock_rate(Config),
            {Core, Effects} = peace_core:init(Config, Stored, now_ms(Clock)),
            ElectionMs = maps:get(election_timeout_ms, Config, ?DEFAULT_ELECTION_TIMEOUT_MS),
            State = #state{
                core = Core,
                tracer = tracer(Config),
                clock = Clock,
                storage_mod = StorageMod,
                storage = Storage,
                election_ms = ElectionMs,
                heartbeat_ms = maps:get(heartbeat_ms, Config, max(1, ElectionMs div 5))
            },
            State1 = perform(Effects, State),
            ok = trace(State1, {Id, init, undefined, Core, Effects}),
            {ok, State1};
        {error, Reason} ->
            {stop, {invalid_quorum, Reason}}
    end.

handle_call({value, Value}, From, State) ->
    {noreply, event({value, From, Value}, State)};
handle_call({value, Value, Session}, From, State) ->
    {noreply, event({value, From, Value, Session}, State)};
handle_call({reconfigure, New}, From, State) ->
    {noreply, event({reconfigure, From, New}, State)};
handle_call({consistent_query, Fun}, From, State) ->
    {noreply, event({query, From, Fun}, State)};
handle_call({local_query, Fun}, _From, State = #state{core = Core}) ->
    Reply =
        try
            {ok, Fun(peace_core:machine_state(Core)), peace_core:leader(Core)}
        catch
            Class:Reason -> {error, {query_failed, Class, Reason}}
        end,
    {reply, Reply, State};
handle_call(members, _From, State = #state{core = Core}) ->
    {reply, {ok, peace_core:members(Core), peace_core:leader(Core)}, State};
handle_call(overview, _From, State = #state{core = Core}) ->
    {reply, peace_core:overview(Core), State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({value, Value}, State) ->
    {noreply, event({value, undefined, Value}, State)};
handle_cast(trigger_election, State) ->
    {noreply, event(force_election, State)};
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info({timeout, Ref, Timer}, State = #state{timers = Timers}) ->
    case Timers of
        #{Timer := Ref} ->
            Event =
                case Timer of
                    election -> election_timeout;
                    heartbeat -> heartbeat_timeout
                end,
            {noreply, event(Event, State#state{timers = maps:remove(Timer, Timers)})};
        _ ->
            %% The timer was cancelled or replaced after it fired.
            {noreply, State}
    end;
handle_info({peace_msg, Peer, Msg}, State) ->
    {noreply, event({msg, Peer, Msg}, State)};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #state{connecting = Connecting}) ->
    {noreply, State#state{connecting = maps:filter(fun(_Node, R) -> R =/= Ref end, Connecting)}};
handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{storage_mod = Mod, storage = Storage}) ->
    _ = peace_storage:close(Mod, Storage),
    ok.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

-ifdef(TEST).
%% A test build may set `unsafe_no_quorum_check', to start a cluster that
%% is deliberately broken. The setting skips all of `check_quorum1/2': the
%% validation of the quorum system and the check of the bound on
%% `read_lease_ms'.
check_quorum(#{unsafe_no_quorum_check := true}, _Members) -> ok;
check_quorum(Config, Members) -> check_quorum1(Config, Members).
-else.
check_quorum(Config, Members) -> check_quorum1(Config, Members).
-endif.

check_quorum1(Config, Members) ->
    Election = maps:get(election_timeout_ms, Config, ?DEFAULT_ELECTION_TIMEOUT_MS),
    case Config of
        %% This limit is not needed for safety. With a longer lease, a
        %% follower would still be bound by the lease when its election
        %% timeout expired, and the follower would only wait again.
        #{read_lease_ms := Lease} when not is_integer(Lease); Lease < 1; Lease > Election ->
            {error, {read_lease_must_not_exceed_election_timeout, Lease, Election}};
        _ ->
            peace_quorum:validate(maps:get(quorum, Config, majority), Members)
    end.

event(Event, State = #state{core = Core0}) ->
    {Core, Effects} = peace_core:handle(Event, now_ms(State#state.clock), Core0),
    _ = ?TRACE(Event, Core),
    State1 = perform(Effects, State#state{core = Core}),
    ok = trace(State1, {peace_core:id(Core), Event, Core0, Core, Effects}),
    State1.

%% A test build may supply a function that is called with each step, after
%% the step has been performed. A test uses the function to check a run
%% against the model. See `dst/peace_dst_trace'.
-ifdef(TEST).
tracer(Config) -> maps:get(test_tracer, Config, undefined).

trace(#state{tracer = undefined}, _Step) ->
    ok;
trace(#state{tracer = Tracer}, Step) ->
    _ = Tracer(Step),
    ok.
-else.
tracer(_Config) -> undefined.

trace(_State, _Step) -> ok.
-endif.

%% Performs the persist effects first, in one write. Then performs every
%% other effect in the order given.
perform(Effects, State0) ->
    {Batches, Rest} = lists:partition(fun(E) -> element(1, E) =:= persist end, Effects),
    State1 = persist([Batch || {persist, Batch} <- Batches], State0),
    lists:foldl(fun effect/2, State1, Rest).

persist([], State) ->
    State;
persist(Batches, State = #state{storage_mod = Mod, storage = Storage0}) ->
    {ok, Storage} = peace_storage:write(Mod, lists:foldl(fun merge_batch/2, #{}, Batches), Storage0),
    State#state{storage = Storage}.

%% Merges one batch into the write.
%%   - A later batch overrides an earlier batch. For entries, the later
%%     batch overrides the earlier batch index by index.
%%   - A snapshot removes from the write every entry that the snapshot
%%     covers.
merge_batch(Batch, Acc0) ->
    Acc1 = maps:merge(Acc0, maps:with([promised, snapshot], Batch)),
    Entries = maps:merge(
        maps:from_list(maps:get(entries, Acc1, [])),
        maps:from_list(maps:get(entries, Batch, []))
    ),
    Floor =
        case Acc1 of
            #{snapshot := {Index, _}} -> Index;
            _ -> 0
        end,
    case lists:sort([E || E = {I, _} <- maps:to_list(Entries), I > Floor]) of
        [] -> maps:remove(entries, Acc1);
        Kept -> Acc1#{entries => Kept}
    end.

effect({send, To, Msg}, State = #state{core = Core}) ->
    send(To, {peace_msg, peace_core:id(Core), Msg}, State);
effect({reply, undefined, _Reply}, State) ->
    State;
effect({reply, From, Reply}, State) ->
    gen_server:reply(From, Reply),
    State;
effect({timer, Timer, cancel}, State) ->
    cancel(Timer, State);
effect({timer, Timer, reset}, State0) ->
    State = #state{timers = Timers} = cancel(Timer, State0),
    Ref = erlang:start_timer(duration(Timer, State), self(), Timer),
    State#state{timers = Timers#{Timer => Ref}};
effect({machine, Effects}, State) ->
    lists:foreach(fun machine_effect/1, Effects),
    State.

%% A server must not wait on the network. A plain send to a node that is not
%% connected blocks the sender while the connection is set up. If the node is
%% down, the sender is blocked for seconds. `gen_server:cast/2' avoids the
%% block by spawning a process per message. This function does the following
%% instead:
%%   - It drops the message. The protocol already tolerates a dropped
%%     message, because everything is retransmitted on the heartbeat.
%%   - It spawns one process per unreachable node. That process connects to
%%     the node.
send(To = {_Name, Node}, Msg, State = #state{connecting = Connecting}) ->
    case catch erlang:send(To, Msg, [noconnect]) of
        noconnect when not is_map_key(Node, Connecting) ->
            {_Pid, Ref} = erlang:spawn_monitor(fun() -> net_kernel:connect_node(Node) end),
            State#state{connecting = Connecting#{Node => Ref}};
        _ ->
            State
    end.

%% The call to `erlang:monotonic_time/1' is module-qualified, so that a
%% simulation can substitute its own clock. The rate is 1, except in a test
%% build that configures a clock that drifts.
now_ms({Num, Den}) ->
    erlang:monotonic_time(millisecond) * Num div Den.

%% Read leases assume that the servers' clocks run at nearly the same rate.
%% A test build can give a server a clock that runs at a different rate, to
%% test the margin of that assumption.
-ifdef(TEST).
clock_rate(Config) -> maps:get(test_clock_rate, Config, {1, 1}).
-else.
clock_rate(_Config) -> {1, 1}.
-endif.

cancel(Timer, State = #state{timers = Timers}) ->
    case maps:take(Timer, Timers) of
        {Ref, Timers1} ->
            _ = erlang:cancel_timer(Ref),
            State#state{timers = Timers1};
        error ->
            State
    end.

%% Election timeouts are randomised over [T, 2T). The randomisation prevents
%% followers that lose their leader at the same time from splitting the vote
%% repeatedly.
duration(election, #state{election_ms = Ms}) -> Ms + rand:uniform(Ms) - 1;
duration(heartbeat, #state{heartbeat_ms = Ms}) -> Ms.

machine_effect({send_msg, Dest, Msg}) ->
    _ = (catch erlang:send(Dest, Msg, [noconnect])),
    ok;
machine_effect({mod_call, Mod, Fun, Args}) ->
    _ = (catch erlang:apply(Mod, Fun, Args)),
    ok;
machine_effect(_Unknown) ->
    ok.
