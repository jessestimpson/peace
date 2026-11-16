%% @doc A check of the contract between a storage backend and
%% `peace_server'. The check is for the tests of a backend, including a
%% backend that is not part of peace.
%%
%% The contract: after any sequence of writes, `open/2' returns exactly what
%% was written. This holds whether the process that opened the store closed
%% it or was killed while it held the store.
%%
%% The check applies to a backend whose data survives the end of the process
%% that opened the store. `peace_storage_mem' does not pass it.
%%
%% See `peace_storage' for the meaning of each key of a batch.
-module(peace_storage_check).

-export([conforms/3, open_and_close/2]).

-define(ID, {peace_storage_check, node()}).

%% @doc Opens the store in a separate process, closes it, and returns the
%% data that the open recovered. A store that was never written to must
%% return `#{entries => #{}}'.
-spec open_and_close(module(), term()) -> peace_storage:stored().
open_and_close(Mod, Args) ->
    in_owner(Mod, Args, fun(_Mod, State) -> {State, close} end).

%% @doc Runs 6 rounds of random writes that are determined by `Seed'.
%% `Args' is the second argument of `open/2', and must name a store that
%% holds no data. The function raises an error if an open recovers data
%% other than the data that was written.
%%
%% A new owner performs each round. The owner ends the round either by
%% closing the store or by being killed. Every owner must recover everything
%% that all the earlier owners wrote.
-spec conforms(module(), term(), integer()) -> ok.
conforms(Mod, Args, Seed) ->
    _ = lists:foldl(
        fun(_Round, {Model0, Rand0}) ->
            {Raw, Rand1} = batches(Rand0),
            Batches = lawful(Raw, Model0),
            {Roll, Rand2} = rand:uniform_s(Rand1),
            End =
                case Roll < 0.5 of
                    true -> close;
                    false -> kill
                end,
            Recovered = in_owner(Mod, Args, fun(M, State0) ->
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
            Recovered =:= Model0 orelse error({recovered_differs, #{seed => Seed, expected => Model0, recovered => Recovered}}),
            {lists:foldl(fun apply_batch/2, Model0, Batches), Rand2}
        end,
        {#{entries => #{}}, rand:seed_s(exsss, Seed)},
        lists:seq(1, 6)
    ),
    ok.

%% Does the following:
%%   1. Opens the store in a separate process, as a server does.
%%   2. Runs `Fun' on the store.
%%   3. Ends that process in the way that the result of `Fun' requests.
%% Returns the data that the open recovered.
in_owner(Mod, Args, Fun) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        {ok, State0, Stored} = peace_storage:open(Mod, ?ID, Args),
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

%% Removes from the batches the writes that `peace_core' never makes:
%%   - an entry at or below the snapshot
%%   - a snapshot that is not newer than the snapshot that is already stored
lawful([], _Model) ->
    [];
lawful([Batch0 | Rest], Model) ->
    {Floor, _} = maps:get(snapshot, Model, {0, none}),
    Batch1 =
        case Batch0 of
            #{snapshot := {Index, _}} when Index =< Floor -> maps:remove(snapshot, Batch0);
            _ -> Batch0
        end,
    {Floor1, _} = maps:get(snapshot, Batch1, {Floor, none}),
    Batch =
        case Batch1 of
            #{entries := Entries} -> Batch1#{entries := [E || E = {I, _} <- Entries, I > Floor1]};
            _ -> Batch1
        end,
    [Batch | lawful(Rest, apply_batch(Batch, Model))].

batches(Rand0) ->
    {N, Rand1} = rand:uniform_s(8, Rand0),
    lists:mapfoldl(fun(_, R) -> batch(R) end, Rand1, lists:seq(1, N)).

%% Generates one random batch. The batch contains one of the following:
%%   - a promise
%%   - entries
%%   - a promise and entries
%%   - neither a promise nor entries
%%   - a snapshot
%%   - a `meta'
%% The batches use few indexes. Entries are therefore overwritten, as an
%% acceptor overwrites entries, and dropped.
batch(Rand0) ->
    {Kind, Rand1} = rand:uniform_s(6, Rand0),
    {Round, Rand2} = rand:uniform_s(50, Rand1),
    {Count, Rand3} = rand:uniform_s(5, Rand2),
    {Entries, Rand4} = lists:mapfoldl(
        fun(_, R0) ->
            {I, R1} = rand:uniform_s(12, R0),
            {Decided, R2} = rand:uniform_s(3, R1),
            Epoch =
                case Decided of
                    1 -> learned;
                    _ -> {Round, ?ID}
                end,
            {{I, {Epoch, {'$usr', {{Round, ?ID}, I}, {put, I, Round}}}}, R2}
        end,
        Rand3,
        lists:seq(1, Count)
    ),
    %% A batch has one write per index. peace never sends two writes for
    %% one index in a batch.
    Unique = maps:to_list(maps:from_list(Entries)),
    Batch =
        case Kind of
            1 -> #{promised => {Round, ?ID}};
            2 -> #{entries => Unique};
            3 -> #{promised => {Round, ?ID}, entries => Unique};
            4 -> #{};
            %% A snapshot, together with only the entries above the snapshot.
            5 -> #{snapshot => {Count, {{state, Round}, #{}}}, entries => [E || E = {I, _} <- Unique, I > Count]};
            6 -> #{meta => #{node => node(), incarnation => <<Round:128>>}}
        end,
    {Batch, Rand4}.

apply_batch(Batch, Model = #{entries := Entries}) ->
    Model1 =
        case Batch of
            #{promised := Epoch} -> Model#{promised => Epoch};
            _ -> Model
        end,
    Model2 = maps:merge(Model1, maps:with([snapshot, meta], Batch)),
    {Floor, _} = maps:get(snapshot, Model2, {0, none}),
    Merged = maps:merge(Entries, maps:from_list(maps:get(entries, Batch, []))),
    Model2#{entries := maps:filter(fun(I, _) -> I > Floor end, Merged)}.
