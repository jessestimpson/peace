%% A storage backend for tests. The backend keeps nothing and supplies the
%% incarnation of the server. See `peace_storage:stored()'.
-module(peace_incarnation_storage).

-behaviour(peace_storage).

-export([open/2, write/2, close/1]).

open(_ServerId, #{incarnation := Incarnation}) ->
    {ok, nostate, #{incarnation => Incarnation}}.

write(_Batch, State) ->
    {ok, State}.

close(_State) ->
    ok.
