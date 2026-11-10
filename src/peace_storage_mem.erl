%% @doc Volatile storage: nothing outlives the server process.
%%
%% A server on this backend that restarts comes back having forgotten every
%% promise it made, which is exactly the acceptor Paxos does not tolerate. It
%% is safe only if a restarted server never rejoins under the same id. Use it
%% for tests, and `peace_storage_dets' for anything else.
-module(peace_storage_mem).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

open(_ServerId, _Args) ->
    {ok, nostate, #{}}.

write(_Batch, State) ->
    {ok, State}.

close(_State) ->
    ok.
