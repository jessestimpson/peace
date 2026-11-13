%% @doc One member of a peace cluster. This module is the process that runs
%% `peace_core'.
%%
%% `peace_core' computes the effects. This module performs them. This
%% module:
%%
%% <ul>
%% <li>owns the timers and the mailbox, and starts the storage process
%%   `peace_writer', which owns the storage handle,</li>
%% <li>converts calls, casts and timeouts into `peace_core' events, and</li>
%% <li>performs the effects that `peace_core' returns.</li>
%% </ul>
%%
%% The important rule in this module is about ordering. This module
%% performs an effect only after every storage write that the effect
%% depends on has returned. Paxos does not tolerate the failure in which a
%% promise or an acceptance reaches a peer and is then lost in a restart.
%% `perform/2' states which effects depend on which writes.
%%
%% This module handles the events that are in the mailbox as a group and
%% sends one storage write for the group to `peace_writer'. See `event/2'.
%% This module does not wait for the write, except for a write that
%% contains a promise.
%%
%% This module sends a snapshot to another server in chunks, and gives a
%% snapshot that arrived in chunks to `peace_core' as one `install'
%% message. See `peace_transfer'.
%%
%% If the storage backend fails to open or to write, the server stops and
%% is not restarted. See `persist/2'.
-module(peace_server).

-behaviour(gen_server).

-include("peace.hrl").
-include("peace_eta.hrl").
-eta_observe({state, [core, inflight, snapshots]}).

-export([start_link/1, start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([step/0]).

-ifdef(TEST).
-export([coalesce/1, merge_batches/1]).
-endif.

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
%% A simulated run reads the state that a server published when its last
%% callback returned. `await/1' waits inside a callback while the storage
%% process writes. This macro publishes the state before the wait, so that
%% a check that runs during the wait compares the disk with the state that
%% the write belongs to.
-define(PUBLISH(State),
    put(eta_observe:key(), #{
        core => State#state.core,
        inflight => State#state.inflight,
        snapshots => State#state.snapshots
    })
).
%% Counts an occurrence for the statistics of the simulation.
-define(COUNT(Key), peace_dst:bump(Key)).
-else.
-define(COUNT(Key), ok).
-define(PUBLISH(State), ok).
-define(TRACE(Event, Core), ok).
-endif.

%% The maximum number of events in one group. See `event/2'.
-define(MAX_GROUP, 256).

-record(state, {
    core :: peace_core:core(),
    %% The rate of this server's clock, as a fraction. See `clock_rate/1'.
    clock = {1, 1} :: {pos_integer(), pos_integer()},
    %% The storage process. See `peace_writer'.
    writer :: pid(),
    %% `seq' is the sequence number of the last write that was sent to the
    %% storage process. `done' is the sequence number of the last write
    %% that has returned. `inflight' holds the writes between the two, in
    %% order.
    seq = 0 :: non_neg_integer(),
    done = 0 :: non_neg_integer(),
    inflight = [] :: [{pos_integer(), peace_storage:batch()}],
    %% The snapshots that were sent to the storage process and that are not
    %% yet stored, in order. A snapshot has no sequence number. See
    %% `submit/2'.
    snapshots = [] :: [peace_storage:batch()],
    %% The `accept' messages that wait for a write. Each element holds the
    %% sequence number of the write and the effects, in order.
    held = [] :: [{pos_integer(), [peace_core:effect()]}],
    election_ms :: pos_integer(),
    heartbeat_ms :: pos_integer(),
    timers = #{} :: #{election | heartbeat => reference()},
    %% The nodes to which a connection attempt is in progress. See `send/3'.
    connecting = #{} :: #{node() => reference()},
    %% The `stored' events of the writes that have returned and that
    %% `peace_core' has not yet handled. See `event/2'.
    stored = [] :: [peace_core:event()],
    %% The snapshots that this server sends and receives in chunks. See
    %% `peace_transfer'.
    transfer :: peace_transfer:t(),
    %% The monitor of the process that encodes a snapshot, if one runs.
    encoder :: undefined | reference(),
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
%%   - the effects. The step is reported before the effects are performed.
-type step() ::
    {peace:server_id(), init | peace_core:event(), undefined | peace_core:core(), peace_core:core(), [
        peace_core:effect()
    ]}
    | {performed, peace:server_id()}.

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
            {StorageMod, StorageArgs} = maps:get(storage, Config, default_storage()),
            case peace_writer:start_link(Id, StorageMod, StorageArgs) of
                {ok, Writer, Stored} -> init(Config, Writer, Stored);
                {error, Reason} -> {stop, {storage_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {invalid_quorum, Reason}}
    end.

%% The default backend is the write-ahead log, in the directory that the
%% application environment variable `data_dir' names.
default_storage() ->
    {peace_storage_wal, #{dir => application:get_env(peace, data_dir, "peace_data")}}.

init(Config = #{id := Id}, Writer, Stored) ->
    Clock = clock_rate(Config),
    {Core, Effects} = peace_core:init(Config, Stored, now_ms(Clock)),
    ElectionMs = maps:get(election_timeout_ms, Config, ?DEFAULT_ELECTION_TIMEOUT_MS),
    State = #state{
        core = Core,
        tracer = tracer(Config),
        clock = Clock,
        writer = Writer,
        transfer = peace_transfer:new(
            maps:get(snapshot_chunk_bytes, Config, ?DEFAULT_SNAPSHOT_CHUNK_BYTES), ElectionMs
        ),
        election_ms = ElectionMs,
        heartbeat_ms = maps:get(heartbeat_ms, Config, max(1, ElectionMs div 5))
    },
    State1 = perform(Effects, State),
    ok = trace(State1, {Id, init, undefined, Core, Effects}),
    {ok, State1}.

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
handle_cast({value, From = {peace_session, _Pid, _Label}, Value, Session}, State) ->
    {noreply, event({value, From, Value, Session}, State)};
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
handle_info({written, Writer, Seq}, State = #state{writer = Writer}) ->
    {noreply, handle_stored(written(Seq, State))};
handle_info({snapshot_written, Writer}, State = #state{writer = Writer, snapshots = [_Stored | Snapshots]}) ->
    {noreply, State#state{snapshots = Snapshots}};
handle_info({peace_chunk, Peer, {offer, Id}}, State = #state{core = Core, transfer = Transfer0}) ->
    Now = now_ms(State#state.clock),
    {Transfer, Sends} = peace_transfer:offered(Peer, Id, peace_core:commit_index(Core), Now, Transfer0),
    {noreply, send_chunks(Sends, State#state{transfer = Transfer})};
handle_info({peace_chunk, Peer, {chunk, Id, Offset, Bin}}, State0 = #state{transfer = Transfer0}) ->
    Now = now_ms(State0#state.clock),
    {Transfer, Sends, Install} = peace_transfer:chunk(Peer, Id, Offset, Bin, Now, Transfer0),
    State = send_chunks(Sends, State0#state{transfer = Transfer}),
    case Install of
        none -> {noreply, State};
        {install, _Index, _Snapshot} ->
            _ = ?COUNT(snapshots_received),
            {noreply, event({msg, Peer, Install}, State)}
    end;
handle_info({peace_chunk, Peer, {request, Id, Offset}}, State = #state{transfer = Transfer0}) ->
    {Transfer, Sends} = peace_transfer:request(Peer, Id, Offset, Transfer0),
    _ = ?COUNT(chunks_requested),
    {noreply, send_chunks(Sends, State#state{transfer = Transfer})};
handle_info({peace_encoded, Index, Chunks, Size, Crc}, State = #state{transfer = Transfer0}) ->
    {Transfer, Sends} = peace_transfer:encoded(Index, Chunks, Size, Crc, Transfer0),
    {noreply, send_chunks(Sends, State#state{transfer = Transfer})};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #state{encoder = Ref, transfer = Transfer}) ->
    %% If the encoding succeeded, the result arrived before this message.
    {noreply, State#state{encoder = undefined, transfer = peace_transfer:encode_failed(Transfer)}};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #state{connecting = Connecting}) ->
    {noreply, State#state{connecting = maps:filter(fun(_Node, R) -> R =/= Ref end, Connecting)}};
handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{writer = Writer}) ->
    _ = (catch peace_writer:stop(Writer)),
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

%% Handles one event, and then every event that is already in the mailbox,
%% up to `?MAX_GROUP' events. The effects of all of these events are
%% performed together, with one storage write. See `perform/2'.
%%
%% `peace_core' handles a later event of the group before the effects of an
%% earlier event are performed. This is safe because `peace_core' is a pure
%% function.
event(Event, State) ->
    handle_stored(flush(drain(?MAX_GROUP - 1, step(Event, State, [])))).

%% Each write that returned produced `stored' events. `peace_core' handles
%% them before any message that arrives later.
handle_stored(State = #state{stored = []}) ->
    State;
handle_stored(State = #state{stored = [Event | Stored]}) ->
    event(Event, State#state{stored = Stored}).

%% Performs the effects of the steps of a group. `Steps' is in reverse
%% order.
%%
%% A server with a tracer reports the steps before it performs their
%% effects. Such a server waits for the write of the group before any other
%% effect. See `perform/2'. If the server is killed during the wait, the
%% trace holds steps whose write may not have happened and whose other
%% effects were not performed. `peace_dst_trace' removes those steps. The
%% server reports `{performed, Id}' after the effects of a group, so that
%% only the steps of an unfinished group can be removed.
flush({State0, Steps}) ->
    Ordered = lists:reverse(Steps),
    lists:foreach(fun(Step) -> ok = trace(State0, Step) end, Ordered),
    State = perform(lists:append([Effects || {_Id, _Event, _Core0, _Core, Effects} <- Ordered]), State0),
    ok = trace(State, {performed, peace_core:id(State#state.core)}),
    State.

%% Handles one event and adds the step to the group.
%%
%% A step that writes a snapshot starts a new group. The steps before it
%% are performed first. `peace_core' guarantees that every index under a
%% snapshot was written as decided by an earlier event. The separate group
%% keeps that guarantee for writes: no index is written as decided and
%% removed by a snapshot in the same write.
step(Event, State0 = #state{core = Core0}, Steps0) ->
    {Core, Effects} = peace_core:handle(Event, now_ms(State0#state.clock), Core0),
    _ = ?TRACE(Event, Core),
    {State, Steps} =
        case Steps0 =/= [] andalso lists:any(fun is_snapshot/1, Effects) of
            true -> {flush({State0, Steps0}), []};
            false -> {State0, Steps0}
        end,
    {State#state{core = Core}, [{peace_core:id(Core), Event, Core0, Core, Effects} | Steps]}.

is_snapshot({persist, #{snapshot := _}}) -> true;
is_snapshot(_Effect) -> false.

%% Takes from the mailbox the messages that become `peace_core' events
%% without any other work in this module. Every other message stays in the
%% mailbox, and `gen_server' delivers it after the group. The patterns for
%% calls and casts are the message formats of `gen_server'.
drain(0, Acc) ->
    Acc;
drain(N, {State, Steps}) ->
    receive
        {peace_msg, Peer, Msg} ->
            drain(N - 1, step({msg, Peer, Msg}, State, Steps));
        {'$gen_call', From, {value, Value}} ->
            drain(N - 1, step({value, From, Value}, State, Steps));
        {'$gen_call', From, {value, Value, Session}} ->
            drain(N - 1, step({value, From, Value, Session}, State, Steps));
        {'$gen_call', From, {consistent_query, Fun}} ->
            drain(N - 1, step({query, From, Fun}, State, Steps));
        {'$gen_cast', {value, Value}} ->
            drain(N - 1, step({value, undefined, Value}, State, Steps));
        {'$gen_cast', {value, From = {peace_session, _Pid, _Label}, Value, Session}} ->
            drain(N - 1, step({value, From, Value, Session}, State, Steps));
        {written, Writer, Seq} when Writer =:= State#state.writer ->
            drain(N, {written(Seq, State), Steps})
    after 0 ->
        {State, Steps}
    end.

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

%% Performs the effects of a group.
%%
%% The persist effects of the group are merged into one write, which is
%% sent to the storage process. Each other effect is performed as soon as
%% every write that the effect depends on has returned.
%%
%% == A write without a promise ==
%%
%% Most writes contain only entries: the proposals of this server as
%% leader, the proposals that this server accepts as a follower, and
%% `learned' entries. Some writes also contain a snapshot. This module does
%% not wait for such a write. While the write is in progress, this module
%% handles further events.
%%
%% A snapshot replaces decided entries with the state that they produce. No
%% effect depends on the write of a snapshot. If the server stops before
%% the write returns, the server restarts from the earlier snapshot and the
%% entries above it, which the storage still holds.
%%
%% The only effect that depends on such a write is the `accept' message,
%% which states that this server has stored a proposal. An `accept' message
%% is held until every write that was sent before it has returned. Every
%% other effect is performed at once:
%%
%% <ul>
%% <li>A `propose' message is the message of a proposer. A proposer does
%%   not have to store its proposal before it sends it. The leader therefore
%%   writes at the same time as the followers. This is the optimisation of
%%   section 10.2.1 of the Raft dissertation (Ongaro, 2014), "Writing to the
%%   leader's disk in parallel". It is not in the thesis. If the leader
%%   stops before its write returns, the leader restarts without its own
%%   acceptance, which is the same as a leader that never accepted its own
%%   proposal. The leader does not propose a second value in the same
%%   epoch, because the promise of the leader for its epoch was written
%%   before the leader sent its `prepare' messages.</li>
%% <li>A reply to a client, a machine effect and the commit index in a
%%   `propose' message depend on a decision. `peace_core' counts the
%%   acceptance of the leader only after the `stored' event, which this
%%   module sends after the write has returned. A decision therefore
%%   depends only on acceptances that are stored. See "The acceptance of
%%   the leader" in `peace_core'.</li>
%% <li>`learned' and `install' messages carry decided values.</li>
%% <li>`nack', `prevote', `prevote_ok' and `catchup' messages state nothing
%%   that the sender must store.</li>
%% </ul>
%%
%% == A write with a promise ==
%%
%% This module waits for a write that contains `promised', and then
%% performs the effects of the group. `prepare' and `promise'
%% messages occur only in such a group. The storage process performs writes
%% in order, so every earlier write has also returned. A `promise' message
%% reports the entries that this server has accepted, and every one of
%% those entries is then stored.
%%
%% == A server with a tracer ==
%%
%% A server that has a tracer waits for every write. Trace validation
%% compares each step with the TLA+ model, in which a server holds an entry
%% from the moment the server accepts it. A server that does not wait holds
%% an accepted entry in memory before the entry is stored, and loses the
%% entry if the server is killed before the write returns. That is safe,
%% because the `accept' message for the entry was not sent, but it is not a
%% behaviour of the model. With a tracer, the only steps that can be lost
%% are the steps of the group that the server was waiting for when it was
%% killed, and none of their effects was performed. Trace validation
%% therefore does not cover writes that are in progress. The simulation
%% and the Jepsen test cover them.
perform(Effects, State0) ->
    {Batches, Rest0} = lists:partition(fun(E) -> element(1, E) =:= persist end, Effects),
    Rest = coalesce(Rest0),
    {Batch, Entries} = merge_batches([Batch0 || {persist, Batch0} <- Batches]),
    case {Batch, Entries andalso State0#state.tracer =:= undefined} of
        {Batch, true} ->
            {Accepts, Others} = lists:partition(fun is_accept/1, Rest),
            State1 = lists:foldl(fun effect/2, submit(Batch, State0), Others),
            hold(Accepts, State1);
        {Batch, false} ->
            lists:foldl(fun effect/2, await(submit(Batch, State0)), Rest)
    end.

is_accept({send, _Peer, {accept, _Epoch, _Indexes, _Stamp}}) -> true;
is_accept(_Effect) -> false.

%% Sends a write to the storage process.
%%
%% A snapshot is sent separately from the rest of the write, and without a
%% sequence number. The storage process performs later writes while it
%% stores the snapshot (see `peace_writer'), so the snapshot may be stored
%% after a write that was sent later. No effect waits for a snapshot:
%%
%% <ul>
%% <li>Until the snapshot is stored, storage holds the earlier snapshot and
%%   every entry that this server accepted. A server that restarts from that
%%   state is bound by every promise and every acceptance that it sent.</li>
%% <li>If the snapshot came from another server, storage may then hold
%%   entries above the index of the snapshot and no entries at some indexes
%%   below it. This server did not accept a value at those indexes. After a
%%   restart, this server asks for those indexes again.</li>
%% </ul>
submit(Batch = #{snapshot := Snapshot}, State = #state{writer = Writer, snapshots = Snapshots}) ->
    Only = #{snapshot => Snapshot},
    ok = peace_writer:snapshot(Writer, Only),
    submit(maps:remove(snapshot, Batch), State#state{snapshots = Snapshots ++ [Only]});
submit(Batch, State) when map_size(Batch) =:= 0 ->
    State;
submit(Batch, State = #state{writer = Writer, seq = Seq0, inflight = Inflight}) ->
    Seq = Seq0 + 1,
    ok = peace_writer:write(Writer, Seq, Batch),
    State#state{seq = Seq, inflight = Inflight ++ [{Seq, Batch}]}.

%% Performs `accept' messages now if no write is in progress. Otherwise the
%% messages wait for the last write that was sent.
hold([], State) ->
    State;
hold(Accepts, State = #state{seq = Seq, done = Seq}) ->
    lists:foldl(fun effect/2, State, Accepts);
hold(Accepts, State = #state{seq = Seq, held = Held}) ->
    State#state{held = Held ++ [{Seq, Accepts}]}.

%% Waits until every write that was sent has returned. A server with a
%% tracer also waits until every snapshot is stored. If the storage process
%% fails, it exits, and the link stops this process.
await(State = #state{seq = Seq, done = Seq, snapshots = Snapshots, tracer = Tracer}) when
    Snapshots =:= []; Tracer =:= undefined
->
    State;
await(State = #state{writer = Writer}) ->
    _ = ?PUBLISH(State),
    receive
        {written, Writer, Seq} ->
            await(written(Seq, State));
        {snapshot_written, Writer} ->
            await(State#state{snapshots = tl(State#state.snapshots)})
    end.

%% The storage process reports that every write up to `Seq' has returned.
%% This function performs the `accept' messages that waited for those
%% writes, and records the `stored' events of those writes.
written(Seq, State = #state{core = Core, inflight = Inflight0, held = Held0, stored = Stored}) ->
    {Returned, Inflight} = lists:splitwith(fun({S, _Batch}) -> S =< Seq end, Inflight0),
    {Ready, Held} = lists:splitwith(fun({S, _Accepts}) -> S =< Seq end, Held0),
    Events = [E || {_S, Batch} <- Returned, E <- peace_core:stored_events(peace_core:id(Core), Batch)],
    State1 = State#state{done = Seq, inflight = Inflight, held = Held, stored = Stored ++ Events},
    lists:foldl(fun effect/2, State1, lists:append([Accepts || {_S, Accepts} <- Ready])).

%% Reduces the effects of a group to fewer effects with the same result.
%%
%% <ul>
%% <li>Consecutive `propose' messages of one epoch to one peer become one
%%   message. The message holds the entries of all of them, the highest
%%   commit index and the latest clock reading. The latest clock reading is
%%   correct for the lease, because the message is sent after that
%%   reading.</li>
%% <li>Consecutive `accept' messages of one epoch to one peer become one
%%   message, with the indexes of all of them and the latest clock reading
%%   that is echoed.</li>
%% <li>Only the last effect on each timer is kept.</li>
%% </ul>
%%
%% Two messages to one peer are consecutive if no other message to that peer
%% lies between them. The order of the messages to one peer is kept.
coalesce(Effects) ->
    coalesce(Effects, #{}, #{}, []).

%% `Open' maps a peer to the message that is being built for that peer.
coalesce([{send, Peer, Msg} | Rest], Open, Timers, Out) ->
    case {Msg, Open} of
        {{propose, Epoch, Entries, Commit, Stamp}, #{Peer := {propose, Epoch, Entries0, Commit0, _Stamp0}}} ->
            Merged = {propose, Epoch, [Entries | Entries0], max(Commit, Commit0), Stamp},
            coalesce(Rest, Open#{Peer := Merged}, Timers, Out);
        {{accept, Epoch, Indexes, Stamp}, #{Peer := {accept, Epoch, Indexes0, Stamp0}}} ->
            Merged = {accept, Epoch, [Indexes | Indexes0], max(Stamp, Stamp0)},
            coalesce(Rest, Open#{Peer := Merged}, Timers, Out);
        _ ->
            Out1 = close(Peer, Open, Out),
            case Msg of
                {propose, Epoch, Entries, Commit, Stamp} ->
                    coalesce(Rest, Open#{Peer => {propose, Epoch, [Entries], Commit, Stamp}}, Timers, Out1);
                {accept, Epoch, Indexes, Stamp} ->
                    coalesce(Rest, Open#{Peer => {accept, Epoch, [Indexes], Stamp}}, Timers, Out1);
                _ ->
                    coalesce(Rest, maps:remove(Peer, Open), Timers, [{send, Peer, Msg} | Out1])
            end
    end;
coalesce([{timer, Timer, Op} | Rest], Open, Timers, Out) ->
    coalesce(Rest, Open, Timers#{Timer => Op}, Out);
coalesce([Effect | Rest], Open, Timers, Out) ->
    coalesce(Rest, Open, Timers, [Effect | Out]);
coalesce([], Open, Timers, Out0) ->
    Out = lists:foldl(fun(Peer, Out1) -> close(Peer, Open, Out1) end, Out0, lists:sort(maps:keys(Open))),
    lists:reverse(Out) ++ [{timer, Timer, Op} || {Timer, Op} <- lists:sort(maps:to_list(Timers))].

%% Adds the message that is being built for `Peer', if any, to `Out'. The
%% parts of the message were collected in reverse order.
close(Peer, Open, Out) ->
    case Open of
        #{Peer := {propose, Epoch, Parts, Commit, Stamp}} ->
            [{send, Peer, {propose, Epoch, lists:append(lists:reverse(Parts)), Commit, Stamp}} | Out];
        #{Peer := {accept, Epoch, Parts, Stamp}} ->
            [{send, Peer, {accept, Epoch, lists:append(lists:reverse(Parts)), Stamp}} | Out];
        _ ->
            Out
    end.

%% Merges the batches of a group into one write.
%%   - A later batch overrides an earlier batch. For entries, the later
%%     batch overrides the earlier batch index by index.
%%   - A snapshot removes from the write every entry that the snapshot
%%     covers.
%%
%% The second element of the result is false if the write contains
%% `promised'. See `perform/2'.
%%
%% A write that contains only `learned' entries has `sync => false'. A
%% `learned' entry records that an index is decided. The decision itself is
%% already durable, because a phase-two quorum has stored its acceptances.
%% If the `learned' entry is lost in a restart, the server holds the index
%% as accepted and learns again that it is decided.
-spec merge_batches([peace_storage:batch()]) -> {peace_storage:batch(), boolean()}.
merge_batches(Batches) ->
    {Fields, Entries} = lists:foldl(
        fun(Batch, {Fields0, Entries0}) ->
            {
                maps:merge(Fields0, maps:with([promised, snapshot], Batch)),
                lists:foldl(fun({I, Entry}, Acc) -> Acc#{I => Entry} end, Entries0, maps:get(entries, Batch, []))
            }
        end,
        {#{}, #{}},
        Batches
    ),
    Floor =
        case Fields of
            #{snapshot := {Index, _}} -> Index;
            _ -> 0
        end,
    Merged =
        case lists:sort([E || E = {I, _} <- maps:to_list(Entries), I > Floor]) of
            [] ->
                Fields;
            Kept when map_size(Fields) =:= 0 ->
                case lists:all(fun({_I, Entry}) -> element(1, Entry) =:= learned end, Kept) of
                    true -> #{entries => Kept, sync => false};
                    false -> #{entries => Kept}
                end;
            Kept ->
                Fields#{entries => Kept}
        end,
    {Merged, not is_map_key(promised, Fields)}.

effect({send, To, {install, Index, Snapshot}}, State = #state{core = Core, transfer = Transfer0}) ->
    %% A snapshot is not sent as one message. See `peace_transfer'.
    {Transfer, Action} = peace_transfer:offer(To, Index, peace_core:snapshot_index(Core), Transfer0),
    case Action of
        none -> State#state{transfer = Transfer};
        encode -> encode(Index, Snapshot, State#state{transfer = Transfer});
        Send -> send_chunks([Send], State#state{transfer = Transfer})
    end;
effect({send, To, Msg}, State = #state{core = Core}) ->
    send(To, {peace_msg, peace_core:id(Core), Msg}, State);
effect({reply, undefined, _Reply}, State) ->
    State;
effect({reply, {peace_session, Pid, Label}, Reply}, State) ->
    %% The value came from a `peace_session' process, in a cast. The reply
    %% is not sent if the node of the process is not connected. The process
    %% submits the value again when no reply arrives.
    _ = catch erlang:send(Pid, {peace_session_reply, Label, Reply}, [noconnect]),
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

send_chunks(Sends, State = #state{core = Core}) ->
    Id = peace_core:id(Core),
    lists:foldl(fun({send, To, Msg}, State1) -> send(To, {peace_chunk, Id, Msg}, State1) end, State, Sends).

%% Starts a process that encodes a snapshot. The encoding of a large
%% snapshot takes long, and this process must not wait for it. The start of
%% the process copies the snapshot, except for the binaries of more than 64
%% bytes that the snapshot contains.
encode(Index, Snapshot, State = #state{transfer = Transfer}) ->
    Server = self(),
    Bytes = peace_transfer:chunk_bytes(Transfer),
    {_Pid, Ref} = erlang:spawn_monitor(fun() ->
        {Chunks, Size} = peace_chunks:encode(Snapshot, Bytes),
        Server ! {peace_encoded, Index, Chunks, Size, peace_chunks:crc(Chunks)}
    end),
    State#state{encoder = Ref}.

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
