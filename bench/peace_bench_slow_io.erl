%% @doc A file module for the write-ahead log backend that makes every sync
%% slower. The `slow_disk' suite of `peace_bench' uses this module to give
%% one server a slow disk.
%%
%% `set/1' sets the delay, in milliseconds, of every sync on the node that
%% it is called on. The delay is 0 until `set/1' is called. The other
%% functions are the functions that `peace_storage_wal' calls on its `io'
%% module.
-module(peace_bench_slow_io).

-export([set/1]).
-export([open/2, write/2, datasync/1, rename/2]).

-spec set(non_neg_integer()) -> ok.
set(DelayMs) ->
    persistent_term:put(?MODULE, DelayMs).

open(File, Modes) -> file:open(File, Modes).

write(Fd, Data) -> file:write(Fd, Data).

datasync(Fd) ->
    case persistent_term:get(?MODULE, 0) of
        0 -> ok;
        DelayMs -> timer:sleep(DelayMs)
    end,
    file:datasync(Fd).

rename(From, To) -> file:rename(From, To).
