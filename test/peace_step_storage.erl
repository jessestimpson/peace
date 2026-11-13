%% A storage backend for tests of `peace_writer'. The backend stores a
%% snapshot in three steps. Each step waits for the message `go' from the
%% test process, so that the test decides what happens between two steps.
%%
%% Args: `#{test := pid()}'. The backend sends `{began, Batch}',
%% `{step, self()}' and `{wrote, Batch}' to that process.
-module(peace_step_storage).

-behaviour(peace_storage).

-export([open/2, write/2, close/1, snapshot_begin/2, snapshot_continue/1]).

open(_Id, #{test := Test}) ->
    {ok, {Test, 0}, #{}}.

write(Batch, State = {Test, _Left}) ->
    Test ! {wrote, Batch},
    {ok, State}.

snapshot_begin(Batch, {Test, 0}) ->
    Test ! {began, Batch},
    {more, {Test, 3}}.

snapshot_continue({Test, Left}) ->
    Test ! {step, self()},
    receive
        go -> ok
    end,
    case Left of
        1 -> {done, {Test, 0}};
        _ -> {more, {Test, Left - 1}}
    end.

close(_State) ->
    ok.
