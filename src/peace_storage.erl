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

-export([open/3, write/3, close/2]).

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
-type batch() :: #{
    promised => peace:epoch(),
    entries => [{peace:index(), peace_core:entry()}],
    snapshot => {peace:index(), peace_core:snapshot()}
}.

%% An `{error, Reason}' result, or an exception, means that the backend
%% cannot guarantee the data. `peace_server' then stops and is not
%% restarted.
-callback open(peace:server_id(), Args :: term()) -> {ok, State :: term(), stored()} | {error, term()}.
-callback write(batch(), State :: term()) -> {ok, State :: term()} | {error, term()}.
-callback close(State :: term()) -> ok.

-spec open(module(), peace:server_id(), term()) -> {ok, term(), stored()} | {error, term()}.
open(Mod, ServerId, Args) ->
    Mod:open(ServerId, Args).

-spec write(module(), batch(), term()) -> {ok, term()} | {error, term()}.
write(Mod, Batch, State) ->
    Mod:write(Batch, State).

-spec close(module(), term()) -> ok.
close(Mod, State) ->
    Mod:close(State).
