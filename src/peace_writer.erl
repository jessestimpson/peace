%% @doc The storage process of one server.
%%
%% `peace_server' does not call the storage backend. It sends each write to
%% this process, so that `peace_server' handles events while a write is in
%% progress. This process:
%%
%% <ul>
%% <li>opens the storage backend and owns the storage handle,</li>
%% <li>performs the writes in the order in which they were sent, and</li>
%% <li>tells the server which writes have returned.</li>
%% </ul>
%%
%% == Group commit ==
%%
%% A write is a cast `{write, Seq, Batch}'. `Seq' is a sequence number that
%% the server assigns. When this process takes a write from its mailbox, it
%% also takes every other write that is already in the mailbox, up to
%% `?MAX_WRITES' writes. It merges the batches and calls the backend once.
%% One sync therefore serves every write that arrived during the previous
%% sync. After the call returns, this process sends
%% `{written, self(), Seq}' to the server, where `Seq' is the highest
%% sequence number in the merged write.
%%
%% == Failure ==
%%
%% If the backend fails to write, this process exits with the reason
%% `{shutdown, {storage_failed, Reason}}'. The server is linked to this
%% process and exits with the same reason. `peace_sup' does not restart a
%% server that exits with a `shutdown' reason. After a failed write or a
%% failed sync the contents of the files are not known, and a restart could
%% recover data that is not durable.
%%
%% == Restart ==
%%
%% This process registers a name that is derived from the name of the
%% server. A server that restarts starts a new storage process. The new
%% process must not open the files while the old process may still write to
%% them. `start_link/3' therefore waits until the old process has stopped.
-module(peace_writer).

-behaviour(gen_server).

-include("peace_eta.hrl").

-export([start_link/3, write/3, stop/1, name/1, merge/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% The maximum number of writes that are merged into one call to the
%% backend.
-define(MAX_WRITES, 64).

%% The time to wait for the storage process of an earlier server process
%% to stop.
-define(STOP_TIMEOUT_MS, 5000).

-record(state, {
    server :: pid(),
    mod :: module(),
    storage :: term()
}).

%% @doc Starts the storage process of the server `Id' and opens the
%% backend. The calling process is the server. Returns the data that the
%% backend recovered.
-spec start_link(peace:server_id(), module(), term()) ->
    {ok, pid(), peace_storage:stored()} | {error, term()}.
start_link(Id = {Name, _Node}, Mod, Args) ->
    case gen_server:start_link({local, name(Name)}, ?MODULE, {self(), Id, Mod, Args}, []) of
        {ok, Pid} ->
            case gen_server:call(Pid, stored, infinity) of
                {ok, Stored} -> {ok, Pid, Stored};
                {error, Reason} -> {error, Reason}
            end;
        {error, {already_started, Old}} ->
            Ref = erlang:monitor(process, Old),
            receive
                {'DOWN', Ref, process, Old, _Reason} -> start_link(Id, Mod, Args)
            after ?STOP_TIMEOUT_MS ->
                _ = erlang:demonitor(Ref, [flush]),
                {error, {storage_process_still_running, Old}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Sends a write. The storage process answers with
%% `{written, Pid, Seq}' after the write, and every write before it, has
%% returned.
-spec write(pid(), pos_integer(), peace_storage:batch()) -> ok.
write(Pid, Seq, Batch) ->
    gen_server:cast(Pid, {write, Seq, Batch}).

%% @doc Closes the backend and stops the storage process.
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%% @doc The registered name of the storage process of the server `Name'.
-spec name(atom()) -> atom().
name(Name) ->
    list_to_atom("peace_writer_" ++ atom_to_list(Name)).

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

%% `init/1' does not fail when the backend fails to open. The server asks
%% for the result with the `stored' call, and this process then stops. The
%% server therefore receives the reason as a value and not as an exit
%% signal.
init({Server, Id, Mod, Args}) ->
    ?ETA_LABEL({writer, Id}),
    case peace_storage:open(Mod, Id, Args) of
        {ok, Storage, Stored} -> {ok, {opened, #state{server = Server, mod = Mod, storage = Storage}, Stored}};
        {error, Reason} -> {ok, {failed, Reason}}
    end.

handle_call(stored, _From, {opened, State, Stored}) ->
    {reply, {ok, Stored}, State};
handle_call(stored, _From, {failed, Reason}) ->
    {stop, normal, {error, Reason}, failed};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({write, Seq, Batch}, State) ->
    write_groups(drain(?MAX_WRITES - 1, [{Seq, [Batch]}]), State);
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{mod = Mod, storage = Storage}) ->
    _ = peace_storage:close(Mod, Storage),
    ok;
terminate(_Reason, _State) ->
    ok.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

%% Calls the backend once for each group, in order, and reports each group
%% to the server.
write_groups([], State) ->
    {noreply, State};
write_groups([{Last, Batches} | Groups], State = #state{server = Server, mod = Mod, storage = Storage0}) ->
    try peace_storage:write(Mod, merge(Batches), Storage0) of
        {ok, Storage} ->
            Server ! {written, self(), Last},
            write_groups(Groups, State#state{storage = Storage});
        {error, Reason} ->
            {stop, {shutdown, {storage_failed, Reason}}, State}
    catch
        Class:Reason:Stack ->
            {stop, {shutdown, {storage_failed, {Class, Reason, Stack}}}, State}
    end.

%% Takes from the mailbox the writes that are already there, and divides
%% them into groups. The pattern is the message format of a `gen_server'
%% cast. Each group holds the highest sequence number of the group and the
%% batches of the group, and both the groups and the batches are returned
%% in the order in which they were sent.
%%
%% A batch with a snapshot is a group of its own. `peace_core' guarantees
%% that every index under a snapshot was written as decided by an earlier
%% write. A merge of the snapshot with the earlier write would remove those
%% entries from the write.
drain(N, Groups) ->
    receive
        {'$gen_cast', {write, Seq, Batch}} when N > 0 ->
            case {Batch, Groups} of
                {#{snapshot := _}, _} ->
                    drain(N - 1, [{Seq, [Batch]} | Groups]);
                {_, [{_Last, [#{snapshot := _}]} | _]} ->
                    drain(N - 1, [{Seq, [Batch]} | Groups]);
                {_, [{_Last, Batches} | Rest]} ->
                    drain(N - 1, [{Seq, [Batch | Batches]} | Rest])
            end
    after 0 ->
        lists:reverse([{Last, lists:reverse(Batches)} || {Last, Batches} <- Groups])
    end.

%% @doc Merges batches into one batch, in order.
%%
%% <ul>
%% <li>A later batch overrides an earlier batch. For entries, the later
%%   batch overrides the earlier batch index by index.</li>
%% <li>A snapshot removes every entry that the snapshot covers.</li>
%% <li>The result has `sync => false' only if every batch has it.</li>
%% </ul>
-spec merge([peace_storage:batch()]) -> peace_storage:batch().
merge([Batch]) ->
    Batch;
merge(Batches) ->
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
            [] -> Fields;
            Kept -> Fields#{entries => Kept}
        end,
    case lists:all(fun(Batch) -> maps:get(sync, Batch, true) =:= false end, Batches) of
        true -> Merged#{sync => false};
        false -> Merged
    end.
