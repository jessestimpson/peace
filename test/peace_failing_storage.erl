%% A storage backend for tests. The backend stores nothing, as
%% `peace_storage_mem' does. A test makes the writes or the open of one
%% server fail with `fail/2'.
-module(peace_failing_storage).

-behaviour(peace_storage).

-export([fail/2]).
-export([open/2, write/2, close/1]).

%% `What' is `write' or `open'.
fail(Id, What) ->
    persistent_term:put({?MODULE, Id}, What).

open(Id, _Args) ->
    case persistent_term:get({?MODULE, Id}, none) of
        open -> {error, injected};
        _ -> {ok, Id, #{}}
    end.

write(_Batch, Id) ->
    case persistent_term:get({?MODULE, Id}, none) of
        write -> {error, injected};
        _ -> {ok, Id}
    end.

close(_Id) ->
    ok.
