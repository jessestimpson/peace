%% What every durable storage backend owes `peace_server': after any sequence
%% of writes, an open returns exactly what was written, whether the previous
%% owner closed the store or was killed holding it.
%%
%% The simulation runs on a disk of its own (`peace_dst_storage'), because a
%% dets table is served by processes the simulation's scheduler does not own.
%% So this is where the shipped backend is held to the contract the
%% simulation assumes of a disk.
-module(peace_storage_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ID, {peace_storage_tests, node()}).

dets_test_() ->
    {timeout, 120, fun() ->
        lists:foreach(fun(Seed) -> conforms(peace_storage_dets, Seed) end, lists:seq(1, 20))
    end}.

%% A store that was never written to recovers nothing, and says so in the
%% shape `peace_core:init/2' reads.
dets_empty_test() ->
    with_dir(fun(Dir) ->
        ?assertEqual(#{entries => #{}}, in_owner(peace_storage_dets, Dir, fun(_Mod, State) -> {State, close} end))
    end).

%% ---------------------------------------------------------------------------

%% Rounds of random writes, each round by a fresh owner that ends by closing
%% or by being killed. Every owner must recover what all the earlier ones
%% wrote.
conforms(Mod, Seed) ->
    with_dir(fun(Dir) ->
        lists:foldl(
            fun(_Round, {Model0, Rand0}) ->
                {Batches, Rand1} = batches(Rand0),
                {Roll, Rand2} = rand:uniform_s(Rand1),
                End =
                    case Roll < 0.5 of
                        true -> close;
                        false -> kill
                    end,
                Recovered = in_owner(Mod, Dir, fun(M, State0) ->
                    State = lists:foldl(
                        fun(Batch, S0) ->
                            {ok, S1} = peace_storage:write(M, Batch, S0),
                            S1
                        end,
                        State0,
                        Batches
                    ),
                    {State, End}
                end),
                ?assertEqual(Model0, Recovered, {seed, Seed}),
                {lists:foldl(fun apply_batch/2, Model0, Batches), Rand2}
            end,
            {#{entries => #{}}, rand:seed_s(exsss, Seed)},
            lists:seq(1, 6)
        ),
        ok
    end).

%% Opens the store in a process of its own, as a server does, runs `Fun' on
%% it, and ends that process the way `Fun' asks. Returns what the open
%% recovered.
in_owner(Mod, Dir, Fun) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        {ok, State0, Stored} = peace_storage:open(Mod, ?ID, #{dir => Dir}),
        Self ! {recovered, self(), Stored},
        case Fun(Mod, State0) of
            {State, close} ->
                ok = peace_storage:close(Mod, State);
            {_State, kill} ->
                Self ! {written, self()},
                receive
                    never -> ok
                end
        end
    end),
    Stored =
        receive
            {recovered, Pid, S} -> S;
            {'DOWN', Ref, process, Pid, Reason} -> error({owner_died, Reason})
        end,
    receive
        {written, Pid} ->
            exit(Pid, kill),
            receive
                {'DOWN', Ref, process, Pid, killed} -> ok
            end;
        {'DOWN', Ref, process, Pid, normal} ->
            ok;
        {'DOWN', Ref, process, Pid, Reason1} ->
            error({owner_died, Reason1})
    end,
    Stored.

batches(Rand0) ->
    {N, Rand1} = rand:uniform_s(8, Rand0),
    lists:mapfoldl(fun(_, R) -> batch(R) end, Rand1, lists:seq(1, N)).

%% Promises, entries, both or neither, over few enough slots that entries
%% are overwritten, as an acceptor overwrites them.
batch(Rand0) ->
    {Kind, Rand1} = rand:uniform_s(4, Rand0),
    {Round, Rand2} = rand:uniform_s(50, Rand1),
    {Count, Rand3} = rand:uniform_s(5, Rand2),
    {Entries, Rand4} = lists:mapfoldl(
        fun(_, R0) ->
            {I, R1} = rand:uniform_s(12, R0),
            {Decided, R2} = rand:uniform_s(3, R1),
            Ballot =
                case Decided of
                    1 -> decided;
                    _ -> {Round, ?ID}
                end,
            {{I, {Ballot, {'$usr', {{Round, ?ID}, I}, {put, I, Round}}}}, R2}
        end,
        Rand3,
        lists:seq(1, Count)
    ),
    %% One write per slot in a batch: peace never sends two.
    Unique = maps:to_list(maps:from_list(Entries)),
    Batch =
        case Kind of
            1 -> #{promised => {Round, ?ID}};
            2 -> #{entries => Unique};
            3 -> #{promised => {Round, ?ID}, entries => Unique};
            4 -> #{}
        end,
    {Batch, Rand4}.

apply_batch(Batch, Model = #{entries := Entries}) ->
    Model1 =
        case Batch of
            #{promised := Ballot} -> Model#{promised => Ballot};
            _ -> Model
        end,
    Model1#{entries := maps:merge(Entries, maps:from_list(maps:get(entries, Batch, [])))}.

with_dir(Fun) ->
    Dir = filename:join([
        filename:basedir(user_cache, "peace_tests"),
        "storage_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    try
        Fun(Dir)
    after
        file:del_dir_r(Dir)
    end.
