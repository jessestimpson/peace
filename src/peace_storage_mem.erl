%% @doc Volatile storage. This backend stores nothing: `write/2' discards
%% the batch and `open/2' recovers no data. No data survives the end of the
%% server process.
%%
%% A server that uses this backend and restarts has lost every promise that
%% it made. Paxos does not tolerate an acceptor that loses its promises. This
%% backend is safe only if a restarted server never rejoins under the same
%% id. Use this backend for tests. Use `peace_storage_wal' for everything
%% else.
-module(peace_storage_mem).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

open(_ServerId, _Args) ->
    {ok, nostate, #{}}.

write(_Batch, State) ->
    {ok, State}.

close(_State) ->
    ok.
