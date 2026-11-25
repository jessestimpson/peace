%% These tests check the contract between every durable storage backend and
%% `peace_server'. After any sequence of writes, an open returns exactly
%% what was written. This holds whether the previous owner closed the store
%% or was killed while the owner held the store. `peace_storage_check'
%% performs the check.
%%
%% The backends are `peace_storage_dets' and `peace_storage_wal'.
%%
%% The simulation also runs the dets backend, but on the replacement for
%% dets that eta provides. The reason is that a real dets table is served by
%% processes that the scheduler of the simulation does not control. These
%% tests therefore check the backend on real dets. The contract checked here
%% is the contract that the simulation assumes of a disk.
-module(peace_storage_tests).

-include_lib("eunit/include/eunit.hrl").

dets_test_() ->
    {timeout, 120, fun() ->
        lists:foreach(fun(Seed) -> conforms(peace_storage_dets, Seed) end, lists:seq(1, 20))
    end}.

wal_test_() ->
    {timeout, 120, fun() ->
        lists:foreach(fun(Seed) -> conforms(peace_storage_wal, Seed) end, lists:seq(1, 20))
    end}.

wal_empty_test() ->
    with_dir(fun(Dir) ->
        ?assertEqual(#{entries => #{}}, peace_storage_check:open_and_close(peace_storage_wal, #{dir => Dir}))
    end).

%% An open of a store that was never written to recovers no data. The open
%% returns that empty result in the shape that `peace_core:init/2' reads.
dets_empty_test() ->
    with_dir(fun(Dir) ->
        ?assertEqual(#{entries => #{}}, peace_storage_check:open_and_close(peace_storage_dets, #{dir => Dir}))
    end).

%% ---------------------------------------------------------------------------

conforms(Mod, Seed) ->
    with_dir(fun(Dir) -> ?assertEqual(ok, peace_storage_check:conforms(Mod, #{dir => Dir}, Seed)) end).

%% `erlang:unique_integer/1' starts from the same values in every Erlang
%% node, so a later run of the tests gets the name of a directory of an
%% earlier run. A run that ends without its cleanup leaves the directory
%% with its data. Each test therefore deletes the directory before it uses
%% the directory, and again after the test.
with_dir(Fun) ->
    Dir = filename:join([
        filename:basedir(user_cache, "peace_tests"),
        "storage_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(Dir),
    try
        Fun(Dir)
    after
        file:del_dir_r(Dir)
    end.
