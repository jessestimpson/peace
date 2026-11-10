%% @doc Where a server keeps what it must not forget.
%%
%% Paxos is safe only if an acceptor that answered is still bound by its
%% answer after a restart. Two things carry that obligation:
%%
%% <ul>
%% <li>the highest ballot it has promised, and</li>
%% <li>every log entry it has accepted, with the ballot it accepted it in (or
%%   the marker `decided' once it knows the entry was chosen).</li>
%% </ul>
%%
%% `peace_server' writes both before it sends the reply that depends on
%% them, and the `write/2' callback must not return until the data would
%% survive whatever failure the deployment is meant to survive.
%%
%% Two backends ship: `peace_storage_dets' (durable, one dets file per
%% server) and `peace_storage_mem' (the process heap, for tests and for
%% clusters that would rather lose a member than wait for a disk).
-module(peace_storage).

-export([open/3, write/3, close/2]).

-export_type([storage/0, stored/0, batch/0]).

-type storage() :: {module(), Args :: term()}.

%% What a server recovers on start.
-type stored() :: #{
    promised => peace:ballot(),
    entries => #{peace:index() => peace_core:entry()}
}.

%% One atomic write. Either key may be absent.
-type batch() :: #{
    promised => peace:ballot(),
    entries => [{peace:index(), peace_core:entry()}]
}.

-callback open(peace:server_id(), Args :: term()) -> {ok, State :: term(), stored()}.
-callback write(batch(), State :: term()) -> {ok, State :: term()}.
-callback close(State :: term()) -> ok.

-spec open(module(), peace:server_id(), term()) -> {ok, term(), stored()}.
open(Mod, ServerId, Args) ->
    Mod:open(ServerId, Args).

-spec write(module(), batch(), term()) -> {ok, term()}.
write(Mod, Batch, State) ->
    Mod:write(Batch, State).

-spec close(module(), term()) -> ok.
close(Mod, State) ->
    Mod:close(State).
