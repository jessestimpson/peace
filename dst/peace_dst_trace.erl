%% Trace validation: a simulated run, restated as a behaviour of
%% `formal/FlexiblePaxos.tla' for TLC to accept or reject.
%%
%% The model is checked exhaustively, but of itself. The simulation checks
%% the code, but against invariants. This is the link between them: every
%% change a server makes to what it has promised and accepted has to be a
%% step the model allows, in the state the model is in by then.
%%
%% == How ==
%%
%% A server in a test build reports each step of its core: the event, the
%% core before and after, the effects (`peace_server', `test_tracer'). From a
%% run's steps, in order, `actions/2' derives the model's actions. It does
%% not ask the code which action it thinks it took. It looks at what changed
%% in the durable state (`promised', the log, the snapshot index) and what
%% was sent, and names the actions that would account for it:
%%
%% <ul>
%% <li>a `prepare' sent in a new epoch is `Prepare'; a promise that rose is
%%   `Promise';</li>
%% <li>an entry stored under the server's own epoch is `Propose' and its own
%%   `Accept'; indexes named in an `accept' it sent are `Accept';</li>
%% <li>an entry that became `learned' is `LeaderLearn' if the server leads
%%   the epoch the entry was held under, `FollowerCommit' if it followed a
%%   `propose', and `CatchUp' if it came by `learned', `install' or a
%%   promise;</li>
%% <li>a snapshot index that rose is `Snapshot' for each index it covers;</li>
%% <li>a `propose' sent with a commit index is `SendCommit' for the indexes
%%   of that epoch it covers.</li>
%% </ul>
%%
%% Anything else that changed (a promise that fell, an entry that vanished
%% above the snapshot) is `Invalid', which the model never allows. After the
%% last action of each step the trace carries what the server then held, and
%% the trace spec (`formal/TraceFlexiblePaxos.tla') requires the model's
%% `promised' and `accepted' to say the same.
%%
%% TLC then has one behaviour to find. Each action must be enabled when its
%% turn comes: a `LeaderLearn' needs the model to hold accepts from a
%% phase-two quorum, a `Propose' needs a phase-one quorum of promises whose
%% reports allow the value, a `SendCommit' needs a leader that has not been
%% contradicted, and so on.
%%
%% == What it does not show ==
%%
%% <ul>
%% <li>The model's messages are every message sent, so an action is allowed
%%   if the messages that justify it were sent, whether or not this server
%%   had received them. A leader that counted a quorum it had not heard from
%%   would pass if the quorum had spoken.</li>
%% <li>A promise raised by a heartbeat is put to the model as `Promise',
%%   which there sends a promise message the code did not send.</li>
%% <li>Only what the model has: no membership change, leases, sessions,
%%   pre-votes or client replies.</li>
%% <li>The rumour of the churn workload names a sender that may not hold the
%%   entries; `CatchUp' is taken from any server that does.</li>
%% </ul>
-module(peace_dst_trace).

-export([event/1, view/1, sends/1]).
-export([steps/1, actions/2, write/4, counts/1]).

-define(NO_EPOCH, {0, none}).

%% ---------------------------------------------------------------------------
%% Recording: called by the server's tracer, inside the run
%% ---------------------------------------------------------------------------

%% What of an event the derivation needs.
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

%% A server's durable state, and the epoch it is running as candidate or
%% leader.
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

%% The steps a run left in its trace table, in order.
steps(Table) ->
    lists:sort([Step || Step <- ets:tab2list(Table), is_integer(element(1, Step))]).

%% ---------------------------------------------------------------------------
%% Deriving the model's actions
%% ---------------------------------------------------------------------------

%% One action is a map: `act', its arguments among `a', `b', `s', `v' and
%% `from' as the code has them, the step it came from, and on the last
%% action of a step, `chk'.
actions(Steps, Ids) ->
    St0 = #{
        ids => Ids,
        %% Per server: what the model holds for it, as far as this needs.
        shadow => maps:from_list([{Id, #{promised => ?NO_EPOCH, log => #{}, snap => 0, learned => #{}}} || Id <- Ids]),
        prepared => #{},
        proposed => #{},
        commits => #{},
        %% Per candidate and epoch: who promised, and the indexes each
        %% reported decided.
        promises => #{},
        acc => []
    },
    St = lists:foldl(fun step/2, St0, Steps),
    lists:reverse(maps:get(acc, St)).

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
    %% From here the model is held to what the server holds.
    Sh = shadow(Id, St3),
    Learned = maps:merge(maps:get(learned, Sh), maps:from_list([{I, true} || {I, {learned, _}} <- maps:to_list(Log)])),
    St4 = put_shadow(Id, Sh#{promised := Promised, log := Log, snap := Snap, learned := Learned}, St3),
    stamp(N, Id, After, Mark, St4).

%% The step's number on each of its actions, and what the server holds on
%% the last.
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

%% The snapshot index covers more: each index newly under it is dropped, and
%% one this server never learned came with an `install'.
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

%% An entry above the snapshot is never given up.
vanished(Id, Log, Snap, St0) ->
    #{log := Old} = shadow(Id, St0),
    lists:foldl(
        fun(I, St) -> emit(#{act => invalid, a => Id, s => I, why => entry_vanished}, St) end,
        St0,
        [I || I <- lists:sort(maps:keys(Old)), I > Snap, not is_map_key(I, Log)]
    ).

%% An accepted `propose': Accept for each index acknowledged, then
%% FollowerCommit for each entry that became decided.
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
%% Anything else is this server acting as proposer, or not at all.
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

%% A step that changed what a server holds and that nothing above accounts
%% for would otherwise pass unseen: no action, so nothing checked.
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

%% Whom to copy a decided index from: the sender if it has it, or anybody
%% who does.
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

%% Appends an action and does to the shadow what the model's action does.
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

%% How many of each action a trace has.
counts(Actions) ->
    lists:foldl(fun(#{act := Act}, Acc) -> maps:update_with(Act, fun(N) -> N + 1 end, 1, Acc) end, #{}, Actions).

%% ---------------------------------------------------------------------------
%% Writing the trace for TLC
%% ---------------------------------------------------------------------------

%% Writes `TraceData.tla', the module `formal/TraceFlexiblePaxos.tla'
%% extends, into `Dir', with `events.txt' beside it for a person: the same
%% actions, numbered as TLC will number them, in the code's own terms.
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

%% Every set of members that is a quorum, by asking `peace_quorum'.
quorums(Is, Quorum, Ids, Env) ->
    set([set([acceptor(Id, Env) || Id <- Set]) || Set <- subsets(Ids), Is(Quorum, Ids, Set)]).

subsets([]) -> [[]];
subsets([H | T]) -> [[H | S] || S <- subsets(T)] ++ subsets(T).

chunks([], _N) -> [];
chunks(List, N) when length(List) =< N -> [List];
chunks(List, N) ->
    {Chunk, Rest} = lists:split(N, List),
    [Chunk | chunks(Rest, N)].
