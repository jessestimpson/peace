%% @doc The storage for the data that a server must keep across a restart.
%%
%% Paxos is safe only if an acceptor that answered is still bound by its
%% answer after a restart. An acceptor must therefore store two things:
%%
%% <ul>
%% <li>the highest epoch that the acceptor has promised, and</li>
%% <li>every log entry that the acceptor has accepted, with the epoch in
%%   which the acceptor accepted the entry (or the marker `learned' once the
%%   acceptor knows that the entry was decided).</li>
%% </ul>
%%
%% A server stores a third thing, a snapshot. A snapshot is the machine
%% state, the session table and the applied configuration as of some index.
%% The snapshot replaces the log entries that have been deleted. The log is
%% no longer kept at or below the index of the snapshot.
%%
%% `peace_server' writes the promised epoch and the accepted entries before
%% it sends the reply that depends on them. The `write/2' callback must not
%% return until the data would survive every failure that the deployment is
%% meant to survive.
%%
%% `peace_server' handles the events that are waiting in its mailbox as a
%% group and makes one call to `write/2' for the group. A backend that syncs
%% once per call therefore performs group commit.
%%
%% peace includes three backends:
%%
%% <ul>
%% <li>`peace_storage_wal' is durable and is the default. It uses a
%%   write-ahead log with a checksum on every record.</li>
%% <li>`peace_storage_dets' is durable. It uses one dets file per
%%   server.</li>
%% <li>`peace_storage_mem' stores nothing. `write/2' discards the batch,
%%   and `open/2' recovers no data. The only copy of the data is the state
%%   of the server process. This backend is for tests, and for clusters in
%%   which losing a member is preferred to waiting for a disk.</li>
%% </ul>
-module(peace_storage).

-export([open/3, write/3, close/2, snapshot_begin/3, snapshot_continue/2]).

-export_type([storage/0, stored/0, batch/0]).

-type storage() :: {module(), Args :: term()}.

%% The data that a server recovers when it starts.
-type stored() :: #{
    promised => peace:epoch(),
    entries => #{peace:index() => peace_core:entry()},
    snapshot => {peace:index(), peace_core:snapshot()}
}.

%% One atomic write. Any key may be absent.
%%
%% `snapshot' replaces the stored snapshot and deletes every entry at or
%% below the index of the snapshot. The entries of the same batch are all
%% above that index. A backend that cannot replace the snapshot and delete
%% the entries in one step writes the snapshot first. That order is safe
%% because `peace_core' ignores entries under the snapshot that it recovers.
%%
%% `sync => false' states that the batch does not have to be durable when
%% `write/2' returns. The batch must become durable no later than the next
%% batch that is written without `sync => false'. A backend may ignore the
%% key and make every batch durable. `peace_server' sets the key for a batch
%% that contains only `learned' entries. See `merge_batches/1' in
%% `peace_server'.
%%
%% `peace_writer' calls the backend. It may merge several batches into one
%% call.
%%
%% == Snapshots in steps ==
%%
%% A backend may export `snapshot_begin/2' and `snapshot_continue/1'.
%% `peace_writer' then stores a snapshot with one call to
%% `snapshot_begin/2' and calls to `snapshot_continue/1' until the result is
%% `done'. `peace_writer' calls `write/2' between these calls, with batches
%% that have no snapshot. The backend must:
%%
%% <ul>
%% <li>keep the stored snapshot and every stored entry until the call that
%%   returns `done', and</li>
%% <li>in that call, replace the snapshot and delete every entry at or below
%%   the index of the snapshot, and keep the promised epoch and the entries
%%   above that index that were written since `snapshot_begin/2'.</li>
%% </ul>
%%
%% A backend without these functions receives the snapshot in a batch, with
%% `write/2'.
-type batch() :: #{
    promised => peace:epoch(),
    entries => [{peace:index(), peace_core:entry()}],
    snapshot => {peace:index(), peace_core:snapshot()},
    sync => boolean()
}.

%% An `{error, Reason}' result, or an exception, means that the backend
%% cannot guarantee the data. `peace_server' then stops and is not
%% restarted.
-callback open(peace:server_id(), Args :: term()) -> {ok, State :: term(), stored()} | {error, term()}.
-callback write(batch(), State :: term()) -> {ok, State :: term()} | {error, term()}.
-callback close(State :: term()) -> ok.
-callback snapshot_begin(batch(), State :: term()) -> {more | done, State :: term()} | {error, term()}.
-callback snapshot_continue(State :: term()) -> {more | done, State :: term()} | {error, term()}.
-optional_callbacks([snapshot_begin/2, snapshot_continue/1]).

-spec open(module(), peace:server_id(), term()) -> {ok, term(), stored()} | {error, term()}.
open(Mod, ServerId, Args) ->
    Mod:open(ServerId, Args).

-spec write(module(), batch(), term()) -> {ok, term()} | {error, term()}.
write(Mod, Batch, State) ->
    Mod:write(Batch, State).

%% @doc Starts to store the snapshot of `Batch'. A backend that does not
%% store a snapshot in steps stores the snapshot in this call.
-spec snapshot_begin(module(), batch(), term()) -> {more | done, term()} | {error, term()}.
snapshot_begin(Mod, Batch, State) ->
    case erlang:function_exported(Mod, snapshot_begin, 2) of
        true ->
            Mod:snapshot_begin(Batch, State);
        false ->
            case Mod:write(Batch, State) of
                {ok, State1} -> {done, State1};
                {error, Reason} -> {error, Reason}
            end
    end.

-spec snapshot_continue(module(), term()) -> {more | done, term()} | {error, term()}.
snapshot_continue(Mod, State) ->
    Mod:snapshot_continue(State).

-spec close(module(), term()) -> ok.
close(Mod, State) ->
    Mod:close(State).
