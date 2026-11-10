%% @doc One member of a peace cluster: the process around `peace_core'.
%%
%% The core decides; this module does what it decided. It owns the storage
%% handle, the timers and the mailbox, turns calls, casts and timeouts into
%% core events, and performs the effects that come back.
%%
%% The one rule that matters here is ordering: everything the core asked to
%% persist is written before anything it asked to send. A promise or an
%% acceptance that reached a peer and then did not survive a restart is the
%% failure Paxos cannot absorb.
-module(peace_server).

-behaviour(gen_server).

-include("peace.hrl").
-include("peace_eta.hrl").
-eta_observe({state, [core]}).

-export([start_link/1, start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% What a simulated run's log says this server did, one line per event.
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
    storage_mod :: module(),
    storage :: term(),
    election_ms :: pos_integer(),
    heartbeat_ms :: pos_integer(),
    timers = #{} :: #{election | heartbeat => reference()},
    %% Nodes a connection attempt is in flight to. See `send/3'.
    connecting = #{} :: #{node() => reference()}
}).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-spec start_link(peace:server_config()) -> {ok, pid()} | {error, term()}.
start_link(Config = #{id := {Name, _Node}}) ->
    gen_server:start_link({local, Name}, ?MODULE, Config, []).

%% @doc Unlinked start, for callers that are not supervisors.
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
            {Core, Effects} = peace_core:init(Config, Stored, now_ms()),
            ElectionMs = maps:get(election_timeout_ms, Config, ?DEFAULT_ELECTION_TIMEOUT_MS),
            State = #state{
                core = Core,
                storage_mod = StorageMod,
                storage = Storage,
                election_ms = ElectionMs,
                heartbeat_ms = maps:get(heartbeat_ms, Config, max(1, ElectionMs div 5))
            },
            {ok, perform(Effects, State)};
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
            %% Cancelled or replaced after it fired.
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

check_quorum(#{unsafe_no_quorum_check := true}, _Members) ->
    %% For tests that need a broken cluster on purpose.
    ok;
check_quorum(Config, Members) ->
    Election = maps:get(election_timeout_ms, Config, ?DEFAULT_ELECTION_TIMEOUT_MS),
    case Config of
        %% Not for safety: a follower bound for longer than it waits before
        %% campaigning would only wait again.
        #{read_lease_ms := Lease} when not is_integer(Lease); Lease < 1; Lease > Election ->
            {error, {read_lease_must_not_exceed_election_timeout, Lease, Election}};
        _ ->
            peace_quorum:validate(maps:get(quorum, Config, majority), Members)
    end.

event(Event, State = #state{core = Core0}) ->
    {Core, Effects} = peace_core:handle(Event, now_ms(), Core0),
    _ = ?TRACE(Event, Core),
    perform(Effects, State#state{core = Core}).

%% Persist first, in one write, then everything else in the order given.
perform(Effects, State0) ->
    {Batches, Rest} = lists:partition(fun(E) -> element(1, E) =:= persist end, Effects),
    State1 = persist([Batch || {persist, Batch} <- Batches], State0),
    lists:foldl(fun effect/2, State1, Rest).

persist([], State) ->
    State;
persist(Batches, State = #state{storage_mod = Mod, storage = Storage0}) ->
    {ok, Storage} = peace_storage:write(Mod, lists:foldl(fun merge_batch/2, #{}, Batches), Storage0),
    State#state{storage = Storage}.

%% Later batches win, index by index, and a snapshot takes out of the write
%% every entry it covers.
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
%% connected blocks the sender while the connection is set up, for seconds if
%% the node is down, and `gen_server:cast/2' avoids that by spawning a process
%% per message. Here the message is simply dropped, which the protocol already
%% tolerates since everything is retransmitted on the heartbeat, and one
%% process per unreachable node goes off to connect.
send(To = {_Name, Node}, Msg, State = #state{connecting = Connecting}) ->
    case catch erlang:send(To, Msg, [noconnect]) of
        noconnect when not is_map_key(Node, Connecting) ->
            {_Pid, Ref} = erlang:spawn_monitor(fun() -> net_kernel:connect_node(Node) end),
            State#state{connecting = Connecting#{Node => Ref}};
        _ ->
            State
    end.

%% Module-qualified, so that a simulation can put its own clock behind it.
now_ms() ->
    erlang:monotonic_time(millisecond).

cancel(Timer, State = #state{timers = Timers}) ->
    case maps:take(Timer, Timers) of
        {Ref, Timers1} ->
            _ = erlang:cancel_timer(Ref),
            State#state{timers = Timers1};
        error ->
            State
    end.

%% Election timeouts are randomised over [T, 2T) so that followers which lose
%% their leader together do not keep splitting the vote.
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
