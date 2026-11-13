%% This module implements trace validation. The module converts a simulated
%% run into a behaviour of `formal/FlexiblePaxos.tla'. TLC then accepts or
%% rejects the behaviour.
%%
%% TLC checks the model exhaustively, but that check covers only the model.
%% The simulation checks the code, but only against invariants. Trace
%% validation connects the model and the code. Every change that a server
%% makes to its promise and to its accepted entries must be a step that the
%% model allows in the state that the model has reached at that point.
%%
%% == Method ==
%%
%% A server in a test build reports each step of its core (`peace_server',
%% `test_tracer'). A report contains:
%%
%% <ul>
%% <li>the event;</li>
%% <li>the core before the step;</li>
%% <li>the core after the step;</li>
%% <li>the effects.</li>
%% </ul>
%%
%% `actions/2' derives the actions of the model from the steps of a run, in
%% order. `actions/2' does not use any statement by the code about which
%% action the code took. `actions/2' examines the change in the durable
%% state (`promised', the log, the snapshot index) and the messages that
%% were sent, and names the actions that explain the change:
%%
%% <ul>
%% <li>A `prepare' sent in a new epoch is `Prepare'.</li>
%% <li>A promise that increased is `Promise'.</li>
%% <li>An entry stored under the epoch of the server itself is `Propose'
%%   and the `Accept' of that server.</li>
%% <li>Each index named in an `accept' that the server sent is
%%   `Accept'.</li>
%% <li>An entry that became `learned' is one of:
%%   <ul>
%%   <li>`LeaderLearn', if the server leads the epoch that the entry was
%%     held under;</li>
%%   <li>`FollowerCommit', if the entry followed a `propose';</li>
%%   <li>`CatchUp', if the entry arrived in a `learned', an `install' or a
%%     promise.</li>
%%   </ul></li>
%% <li>A snapshot index that increased is `Snapshot' for each index that
%%   the snapshot index covers.</li>
%% <li>A `propose' sent with a commit index is `SendCommit' for the indexes
%%   of that epoch that the commit index covers.</li>
%% </ul>
%%
%% Any other change is `Invalid', which the model never allows. Examples are
%% a promise that decreased and an entry that disappeared above the
%% snapshot. The last action of each step carries the state that the server
%% held after the step. The trace spec (`formal/TraceFlexiblePaxos.tla')
%% requires `promised' and `accepted' in the model to equal that state.
%%
%% TLC then has one behaviour to find. Each action must be enabled at its
%% position in the trace. For example:
%%
%% <ul>
%% <li>`LeaderLearn' requires that the model holds accepts from a phase-two
%%   quorum.</li>
%% <li>`Propose' requires a phase-one quorum of promises whose reports allow
%%   the value.</li>
%% <li>`SendCommit' requires a leader that has not been contradicted.</li>
%% </ul>
%%
%% == Limitations ==
%%
%% <ul>
%% <li>The messages of the model are all messages that were ever sent. The
%%   model therefore allows an action if the messages that justify the
%%   action were sent, whether or not this server had received them. A
%%   leader that counted a quorum without having received the messages of
%%   that quorum would pass validation if the members of the quorum had sent
%%   the messages.</li>
%% <li>A promise that a heartbeat raised is given to the model as `Promise'.
%%   In the model, `Promise' sends a promise message. The code did not send
%%   that message.</li>
%% <li>Validation covers only what the model contains. The model has no
%%   membership change, leases, sessions, pre-votes or client replies.</li>
%% <li>The rumour operation of the churn workload names a sender that may
%%   not hold the entries. `CatchUp' is taken from any server that holds the
%%   entries.</li>
%% </ul>
-module(peace_dst_trace).

-export([event/1, view/1, sends/1]).
-export([steps/1, actions/2, write/4, counts/1]).

-define(NO_EPOCH, {0, none}).

%% ---------------------------------------------------------------------------
%% Recording. The tracer of the server calls these functions during the run.
%% ---------------------------------------------------------------------------

%% Returns the parts of an event that the derivation needs.
event({msg, Peer, {propose, Epoch, _Entries, Commit, _Stamp}}) ->
    {propose, Peer, Epoch, Commit};
event({msg, Peer, {promise, Epoch, Entries, _Snap}}) ->
    {promise, Peer, Epoch, [I || {I, learned, _Value} <- Entries]};
event({msg, Peer, {learned, _Entries}}) ->
    {learned, Peer};
event({msg, Peer, {install, _Index, _Snapshot}}) ->
    {install, Peer};
event(init) ->
    init;
event(_Other) ->
    other.

%% Returns the durable state of a server, and the epoch in which the server
%% is running as candidate or leader.
view(undefined) ->
    undefined;
view(Core) ->
    #{
        promised => peace_core:promised(Core),
        log => peace_core:log(Core),
        snap => peace_core:snapshot_index(Core),
        epoch => maps:get(epoch, peace_core:overview(Core))
    }.

sends(Effects) ->
    lists:usort(
        lists:filtermap(
            fun
                ({send, _To, {prepare, Epoch, _From}}) -> {true, {prepare, Epoch}};
                ({send, _To, {propose, Epoch, _Entries, Commit, _Stamp}}) -> {true, {propose, Epoch, Commit}};
                ({send, To, {accept, Epoch, Indexes, _Stamp}}) -> {true, {accept, To, Epoch, Indexes}};
                (_Effect) -> false
            end,
            Effects
        )
    ).

%% Returns the steps that a run recorded in its trace table, in order.
steps(Table) ->
    lists:keysort(1, [Step || Step <- ets:tab2list(Table), is_integer(element(1, Step))]).

%% ---------------------------------------------------------------------------
%% Deriving the model's actions
%% ---------------------------------------------------------------------------

%% One action is a map that contains:
%%   - `act';
%%   - the arguments of the action, among `a', `b', `s', `v' and `from', as
%%     the code represents them;
%%   - the step that the action came from;
%%   - `chk', on the last action of a step only.
actions(Steps, Ids) ->
    St0 = #{
        ids => Ids,
        %% `shadow' holds, for each server, the part of the state of the
        %% model for that server that the derivation needs.
        shadow => maps:from_list([{Id, #{promised => ?NO_EPOCH, log => #{}, snap => 0, learned => #{}}} || Id <- Ids]),
        prepared => #{},
        proposed => #{},
        commits => #{},
        %% `promises' holds, for each candidate and epoch, the servers that
        %% promised and the indexes that each of those servers reported as
        %% decided.
        promises => #{},
        acc => []
    },
    St = lists:foldl(fun step/2, St0, performed(Steps)),
    lists:reverse(maps:get(acc, St)).

%% Removes the steps that a server reported and did not perform.
%%
%% A server reports the steps of a group, then waits for the storage write
%% of the group, then performs the other effects of the group, and then
%% reports `performed'. A server that is killed during the wait has
%% performed none of those effects, and the write may not have happened.
%% When the server starts again, its `init' step holds the state that the
%% server recovered. If that state differs from the state after the last
%% step that the server reported, the write did not happen. This function
%% then removes the steps that the server reported after its last
%% `performed'. The write of a group is atomic, so either all of those steps
%% are removed or none.
performed(Steps) ->
    {Kept, _Open} = lists:foldl(
        fun
            ({_N, Id, performed}, {Acc, Open}) ->
                {Acc, Open#{Id => []}};
            (Step = {_N, Id, init, _Before, After, _Sends}, {Acc, Open}) ->
                Lost =
                    case maps:get(Id, Open, []) of
                        [{_, _, _, _, Last, _} | _] = Unfinished ->
                            case durable(Last) =:= durable(After) of
                                true -> [];
                                false -> Unfinished
                            end;
                        [] ->
                            []
                    end,
                {[Step | Acc -- Lost], Open#{Id => []}};
            (Step = {_N, Id, _Event, _Before, _After, _Sends}, {Acc, Open}) ->
                {[Step | Acc], Open#{Id => [Step | maps:get(Id, Open, [])]}}
        end,
        {[], #{}},
        Steps
    ),
    lists:reverse(Kept).

durable(View) ->
    maps:with([promised, log, snap], View).

step({N, Id, Event, Before, After, Sends}, St0) ->
    #{promised := Promised, log := Log, snap := Snap, epoch := Epoch1} = After,
    Mark = length(maps:get(acc, St0)),
    Own =
        case {Epoch1, Before} of
            {undefined, #{epoch := Epoch0}} -> Epoch0;
            _ -> Epoch1
        end,
    St1 = remember(Id, Event, St0),
    Pipeline = [
        fun(St) -> regress(Id, Promised, St) end,
        fun(St) -> prepares(Id, Sends, Epoch1, St) end,
        fun(St) ->
            case Event of
                {propose, _, _, _} -> St;
                _ -> raise(Id, Promised, St)
            end
        end,
        fun(St) -> snapshot(Id, Event, Snap, St) end,
        fun(St) -> vanished(Id, Log, Snap, St) end,
        fun(St) -> entries(Id, Event, Own, Log, Snap, Sends, St) end,
        fun(St) -> commits(Sends, St) end,
        fun(St) -> raise(Id, Promised, St) end
    ],
    St2 = lists:foldl(fun(F, St) -> F(St) end, St1, Pipeline),
    St3 = unexplained(Id, After, Mark, St2),
    %% From this point, the model is required to hold the same state as the
    %% server holds.
    Sh = shadow(Id, St3),
    Learned = maps:merge(maps:get(learned, Sh), maps:from_list([{I, true} || {I, {learned, _}} <- maps:to_list(Log)])),
    St4 = put_shadow(Id, Sh#{promised := Promised, log := Log, snap := Snap, learned := Learned}, St3),
    stamp(N, Id, After, Mark, St4).

%% Puts the number of the step on each action of the step, and puts the
%% state that the server holds on the last action of the step.
stamp(N, Id, #{promised := Promised, log := Log}, Mark, St = #{acc := Acc}) ->
    {New, Old} = lists:split(length(Acc) - Mark, Acc),
    case [A#{step => N} || A <- New] of
        [] ->
            St;
        [Last | Rest] ->
            Chk = {Id, Promised, lists:sort([{I, Epoch, Value} || {I, {Epoch, Value}} <- maps:to_list(Log)])},
            St#{acc := [Last#{chk => [Chk]} | Rest] ++ Old}
    end.

remember(Id, {promise, Peer, Epoch, Reported}, St = #{promises := Promises}) ->
    Key = {Id, Epoch},
    St#{promises := Promises#{Key => [{Peer, Reported} | maps:get(Key, Promises, [])]}};
remember(_Id, _Event, St) ->
    St.

regress(Id, Promised, St) ->
    case Promised < maps:get(promised, shadow(Id, St)) of
        true -> emit(#{act => invalid, a => Id, why => promise_fell}, St);
        false -> St
    end.

prepares(Id, Sends, Epoch, St) ->
    Epochs = lists:usort([E || {prepare, E} <- Sends] ++ [E || E <- [Epoch], E =/= undefined]),
    lists:foldl(
        fun(E, Acc = #{prepared := Prepared}) ->
            case Prepared of
                #{E := _} -> Acc;
                _ -> emit(#{act => prepare, a => Id, b => E}, Acc)
            end
        end,
        St,
        Epochs
    ).

raise(Id, Promised, St) ->
    case Promised > maps:get(promised, shadow(Id, St)) of
        true -> emit(#{act => promise, a => Id, b => Promised}, St);
        false -> St
    end.

%% The snapshot index increased. The server dropped each index that the
%% snapshot index newly covers. If the server never learned one of those
%% indexes, the index arrived with an `install'.
snapshot(Id, Event, Snap, St0) ->
    #{snap := Old} = shadow(Id, St0),
    case Snap < Old of
        true ->
            emit(#{act => invalid, a => Id, why => snapshot_fell}, St0);
        false ->
            lists:foldl(
                fun(I, St) ->
                    St1 =
                        case {is_learned(Id, I, St), Event} of
                            {true, _} -> St;
                            {false, {install, Peer}} -> emit(#{act => catchup, a => Id, from => source(Peer, I, St), s => I}, St);
                            {false, _} -> emit(#{act => invalid, a => Id, s => I, why => dropped_unlearned}, St)
                        end,
                    emit(#{act => snapshot, a => Id, s => I}, St1)
                end,
                St0,
                lists:seq(Old + 1, Snap)
            )
    end.

%% A server never removes an entry above the snapshot.
vanished(Id, Log, Snap, St0) ->
    #{log := Old} = shadow(Id, St0),
    lists:foldl(
        fun(I, St) -> emit(#{act => invalid, a => Id, s => I, why => entry_vanished}, St) end,
        St0,
        [I || I <- lists:sort(maps:keys(Old)), I > Snap, not is_map_key(I, Log)]
    ).

%% The server accepted a `propose'. The actions are Accept for each index
%% that the server acknowledged, then FollowerCommit for each entry that
%% became decided.
entries(Id, {propose, Peer, Epoch, _Commit}, _Own, Log, _Snap, Sends, St0) ->
    case [Indexes || {accept, To, E, Indexes} <- Sends, To =:= Peer, E =:= Epoch] of
        [] ->
            St0;
        [Indexes | _] ->
            St1 = lists:foldl(fun(I, St) -> emit(#{act => accept, a => Id, b => Epoch, s => I}, St) end, St0, Indexes),
            lists:foldl(
                fun(I, St) -> emit(#{act => follower_commit, a => Id, b => Epoch, s => I}, St) end,
                St1,
                newly_learned(Id, Log, St1)
            )
    end;
entries(Id, {learned, Peer}, _Own, Log, _Snap, _Sends, St0) ->
    lists:foldl(
        fun(I, St) -> emit(#{act => catchup, a => Id, from => source(Peer, I, St), s => I}, St) end,
        St0,
        newly_learned(Id, Log, St0)
    );
%% On any other event, this server either acts as proposer or takes no
%% action.
entries(Id, _Event, Own, Log, Snap, _Sends, St0) ->
    #{log := Old} = shadow(Id, St0),
    lists:foldl(
        fun(I, St) ->
            case {maps:get(I, Old, none), maps:get(I, Log)} of
                {Same, Same} ->
                    St;
                {{Own, Value}, {learned, Value}} when Own =/= undefined ->
                    emit(#{act => leader_learn, b => Own, s => I}, St);
                {_Before, {learned, Value}} ->
                    case {reported(Id, Own, I, St), Own} of
                        {{ok, Peer}, _} ->
                            emit(#{act => catchup, a => Id, from => source(Peer, I, St), s => I}, St);
                        {none, {_, Id}} ->
                            emit(#{act => leader_learn, b => Own, s => I}, accept_own(Id, Own, I, Value, St));
                        {none, _} ->
                            emit(#{act => invalid, a => Id, s => I, why => learned_from_nowhere}, St)
                    end;
                {_Before, {Epoch = {_, Id}, Value}} ->
                    accept_own(Id, Epoch, I, Value, St);
                {_Before, _Foreign} ->
                    emit(#{act => invalid, a => Id, s => I, why => stored_unasked}, St)
            end
        end,
        St0,
        [I || I <- lists:sort(maps:keys(Log)), I > Snap]
    ).

accept_own(Id, Epoch, I, Value, St0 = #{proposed := Proposed}) ->
    St1 =
        case Proposed of
            #{{Epoch, I} := _} -> St0;
            _ -> emit(#{act => propose, b => Epoch, s => I, v => Value}, St0)
        end,
    emit(#{act => accept, a => Id, b => Epoch, s => I}, St1).

commits(Sends, St0 = #{proposed := Proposed}) ->
    lists:foldl(
        fun({Epoch, Commit}, St) ->
            lists:foldl(
                fun(I, Acc = #{commits := Commits}) ->
                    case Commits of
                        #{{Epoch, I} := _} -> Acc;
                        _ -> emit(#{act => send_commit, b => Epoch, s => I}, Acc)
                    end
                end,
                St,
                lists:sort([I || {E, I} <- maps:keys(Proposed), E =:= Epoch, I =< Commit])
            )
        end,
        St0,
        [{Epoch, Commit} || {propose, Epoch, Commit} <- Sends]
    ).

%% Emits `Invalid' for a step that changed the state that a server holds
%% when no function above produced an action for the change. Without this
%% function such a step would not be checked, because a step with no action
%% carries no check.
unexplained(Id, #{promised := Promised, log := Log, snap := Snap}, Mark, St = #{acc := Acc}) ->
    #{promised := P0, log := L0, snap := S0} = shadow(Id, St),
    Kept = maps:filter(fun(I, _) -> I > Snap end, L0),
    case length(Acc) =:= Mark andalso {Promised, Log, Snap} =/= {P0, Kept, S0} of
        true -> emit(#{act => invalid, a => Id, why => unexplained_change}, St);
        false -> St
    end.

newly_learned(Id, Log, St) ->
    [I || {I, {learned, _}} <- lists:sort(maps:to_list(Log)), not is_learned(Id, I, St)].

reported(_Id, undefined, _I, _St) ->
    none;
reported(Id, Epoch, I, #{promises := Promises}) ->
    case [Peer || {Peer, Indexes} <- maps:get({Id, Epoch}, Promises, []), lists:member(I, Indexes)] of
        [Peer | _] -> {ok, Peer};
        [] -> none
    end.

%% Returns the server to copy a decided index from. This server is the
%% sender if the sender holds the index, and otherwise any server that holds
%% the index.
source(Peer, I, St = #{ids := Ids}) ->
    case [Id || Id <- [Peer | Ids], lists:member(Id, Ids), is_learned(Id, I, St)] of
        [Id | _] -> Id;
        [] -> Peer
    end.

is_learned(Id, I, St) ->
    is_map_key(I, maps:get(learned, shadow(Id, St))).

shadow(Id, #{shadow := Shadow}) ->
    maps:get(Id, Shadow).

put_shadow(Id, Sh, St = #{shadow := Shadow}) ->
    St#{shadow := Shadow#{Id := Sh}}.

%% Appends an action, and applies to the shadow the change that the action
%% makes in the model.
emit(Action, St0 = #{acc := Acc}) ->
    St = St0#{acc := [Action | Acc]},
    case Action of
        #{act := prepare, b := E} ->
            St#{prepared := (maps:get(prepared, St))#{E => true}};
        #{act := promise, a := Id, b := E} ->
            Sh = shadow(Id, St),
            put_shadow(Id, Sh#{promised := E}, St);
        #{act := propose, b := E, s := I} ->
            St#{proposed := (maps:get(proposed, St))#{{E, I} => true}};
        #{act := accept, a := Id, b := E} ->
            Sh = #{promised := P} = shadow(Id, St),
            put_shadow(Id, Sh#{promised := max(P, E)}, St);
        #{act := follower_commit, a := Id, b := E, s := I} ->
            Sh = #{learned := L} = shadow(Id, St),
            put_shadow(Id, Sh#{promised := E, learned := L#{I => true}}, St);
        #{act := leader_learn, b := {_, Id}, s := I} ->
            learn(Id, I, St);
        #{act := catchup, a := Id, s := I} ->
            learn(Id, I, St);
        #{act := send_commit, b := E, s := I} ->
            St#{commits := (maps:get(commits, St))#{{E, I} => true}};
        _ ->
            St
    end.

learn(Id, I, St) ->
    case St of
        #{shadow := #{Id := Sh = #{learned := L}}} -> put_shadow(Id, Sh#{learned := L#{I => true}}, St);
        _ -> St
    end.

%% Returns the number of occurrences of each action in a trace.
counts(Actions) ->
    lists:foldl(fun(#{act := Act}, Acc) -> maps:update_with(Act, fun(N) -> N + 1 end, 1, Acc) end, #{}, Actions).

%% ---------------------------------------------------------------------------
%% Writing the trace for TLC
%% ---------------------------------------------------------------------------

%% Writes `TraceData.tla' into `Dir'. `TraceData.tla' is the module that
%% `formal/TraceFlexiblePaxos.tla' extends. Also writes `events.txt' into
%% `Dir' for a human reader. `events.txt' lists the same actions, numbered
%% as TLC numbers them, in the terms that the code uses.
write(Dir, Actions, Ids, Quorum) ->
    Epochs = lists:usort(
        [E || #{b := E} <- Actions] ++
            [E || #{chk := Chks} <- Actions, {_, P, Votes} <- Chks, E <- [P | [VE || {_, VE, _} <- Votes]], E =/= learned]
    ) -- [?NO_EPOCH],
    Rank = maps:from_list(lists:zip(Epochs, lists:seq(1, length(Epochs)))),
    MaxEpoch = max(1, length(Epochs)),
    Values = lists:usort(
        [V || #{v := V} <- Actions] ++ [V || #{chk := Chks} <- Actions, {_, _, Votes} <- Chks, {_, _, V} <- Votes]
    ),
    ValueId = maps:from_list(lists:zip(Values, lists:seq(1, length(Values)))),
    MaxIndex = lists:max(
        [1] ++ [I || #{s := I} <- Actions] ++ [I || #{chk := Chks} <- Actions, {_, _, Votes} <- Chks, {I, _, _} <- Votes]
    ),
    Name = maps:from_list(lists:zip(Ids, lists:seq(1, length(Ids)))),
    Env = #{rank => Rank#{?NO_EPOCH => 0, learned => MaxEpoch + 1}, value => ValueId, name => Name},
    Chunks = chunks([record(A, Env) || A <- Actions], 200),
    Tla = [
        "---------------------------- MODULE TraceData ----------------------------\n",
        "\\* Written by dst/peace_dst_trace.erl. One simulated run.\n",
        "EXTENDS Sequences\n",
        "TraceAcceptors == ", set([acceptor(Id, Env) || Id <- Ids]), "\n",
        "TraceValues == ", set([value(V, Env) || V <- Values]), "\n",
        "TraceMaxEpoch == ", integer_to_list(MaxEpoch), "\n",
        "TraceMaxIndex == ", integer_to_list(MaxIndex), "\n",
        "TraceQuorum1 == ", quorums(fun peace_quorum:is_phase_one_quorum/3, Quorum, Ids, Env), "\n",
        "TraceQuorum2 == ", quorums(fun peace_quorum:is_phase_two_quorum/3, Quorum, Ids, Env), "\n",
        [
            ["TracePart", integer_to_list(K), " == <<\n", lists:join(",\n", Chunk), "\n>>\n"]
         || {K, Chunk} <- lists:zip(lists:seq(1, length(Chunks)), Chunks)
        ],
        "Trace == ",
        case Chunks of
            [] -> "<< >>";
            _ -> lists:join(" \\o ", ["TracePart" ++ integer_to_list(K) || K <- lists:seq(1, length(Chunks))])
        end,
        "\n=============================================================================\n"
    ],
    Listing = [
        io_lib:format("~6b  ~0p~n", [K, maps:without([chk], A)])
     || {K, A} <- lists:zip(lists:seq(1, length(Actions)), Actions)
    ],
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "TraceData.tla"), Tla),
    ok = file:write_file(filename:join(Dir, "TraceData.len"), integer_to_list(length(Actions))),
    ok = file:write_file(filename:join(Dir, "events.txt"), Listing),
    ok.

record(A = #{act := Act}, Env = #{rank := Rank}) ->
    [
        "  [act |-> \"", act(Act), "\"",
        ", a |-> ", acceptor(maps:get(a, A, none), Env),
        ", b |-> ", integer_to_list(maps:get(maps:get(b, A, ?NO_EPOCH), Rank)),
        ", s |-> ", integer_to_list(maps:get(s, A, 0)),
        ", v |-> ", value(maps:get(v, A, none), Env),
        ", from |-> ", acceptor(maps:get(from, A, none), Env),
        ", chk |-> ", tuple([chk(C, Env) || C <- maps:get(chk, A, [])]),
        "]"
    ].

chk({Id, Promised, Votes}, Env = #{rank := Rank}) ->
    tuple([
        acceptor(Id, Env),
        integer_to_list(maps:get(Promised, Rank)),
        tuple([tuple([integer_to_list(I), integer_to_list(maps:get(E, Rank)), value(V, Env)]) || {I, E, V} <- Votes])
    ]).

act(prepare) -> "Prepare";
act(promise) -> "Promise";
act(propose) -> "Propose";
act(accept) -> "Accept";
act(leader_learn) -> "LeaderLearn";
act(send_commit) -> "SendCommit";
act(follower_commit) -> "FollowerCommit";
act(catchup) -> "CatchUp";
act(snapshot) -> "Snapshot";
act(invalid) -> "Invalid".

acceptor(none, _Env) -> "\"\"";
acceptor(Id, #{name := Name}) -> ["\"s", integer_to_list(maps:get(Id, Name)), "\""].

value(none, _Env) -> "\"\"";
value(V, #{value := ValueId}) -> ["\"v", integer_to_list(maps:get(V, ValueId)), "\""].

set(Items) -> ["{", lists:join(", ", Items), "}"].

tuple(Items) -> ["<<", lists:join(", ", Items), ">>"].

%% Returns every set of members that is a quorum. `peace_quorum' decides
%% whether a set is a quorum.
quorums(Is, Quorum, Ids, Env) ->
    set([set([acceptor(Id, Env) || Id <- Set]) || Set <- subsets(Ids), Is(Quorum, Ids, Set)]).

subsets([]) -> [[]];
subsets([H | T]) -> [[H | S] || S <- subsets(T)] ++ subsets(T).

chunks([], _N) -> [];
chunks(List, N) when length(List) =< N -> [List];
chunks(List, N) ->
    {Chunk, Rest} = lists:split(N, List),
    [Chunk | chunks(Rest, N)].
