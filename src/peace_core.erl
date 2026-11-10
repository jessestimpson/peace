%% @doc The Flexible Paxos protocol, as a pure function.
%%
%% `handle/2' takes an event and a state and returns the new state and a list
%% of effects. It sends nothing, writes nothing and reads no clock;
%% `peace_server' does those on its behalf. That keeps the protocol testable
%% without processes, and keeps it close to `formal/FlexiblePaxos.tla', which
%% is the same protocol with the effects left out. Comments below name the
%% TLA+ action each clause corresponds to.
%%
%% == The protocol ==
%%
%% Multi-Paxos with co-located roles and distinct quorums per phase, in the
%% terms of Howard's thesis (UCAM-CL-TR-935, in `docs/'): her sections 3.6,
%% 3.7 and 4.1. Section references below are to it. What the thesis calls an
%% epoch is a ballot here, and its "decided" is this module's `decided'.
%%
%% Every server is proposer, acceptor and learner at once. A ballot is
%% `{Round, ServerId}', so it has exactly one possible leader, and a server
%% leads for as long as nobody promises a higher one.
%%
%% Phase 1, once per leadership. A follower that hears nothing from a leader
%% for an election timeout picks a ballot above any it has seen and sends
%% `{prepare, Ballot, From}', where `From' is its first undecided slot. An
%% acceptor that has promised nothing higher promises, and answers with every
%% log entry it holds from `From' on. With promises from a phase-1 quorum the
%% candidate leads: for every slot anybody reported it re-proposes the value
%% reported at the highest ballot, and fills gaps with no-ops. An acceptor
%% that has promised something higher says so, with the ballot (a NACK,
%% section 3.1), and the candidate stands down and outbids it next time.
%%
%% Phase 2, once per command. The leader assigns the next slot and sends
%% `{accept, Ballot, Entries, Commit}'. An acceptor that has promised nothing
%% higher stores the entries and answers `{accepted, Ballot, Indexes}'. A
%% slot is decided once a phase-2 quorum has accepted it. The two quorum
%% systems only have to intersect each other; see `peace_quorum'.
%%
%% Learning, the thesis's optional phase three (section 3.3, "Termination").
%% A decided entry is kept under the marker `decided' in place of a ballot,
%% and is reported that way in promises, where it outranks every ballot.
%% Entries become decided by three routes, and they are the three learning
%% actions of the TLA+ model:
%%
%% <ul>
%% <li>the leader counts a phase-2 quorum (`LeaderDecide');</li>
%% <li>a follower sees its leader's commit index cover a slot where its own
%%   entry is from that leader's ballot (`FollowerCommit');</li>
%% <li>anybody is told outright, by `{learned, Entries}' in answer to a
%%   `{catchup, From}', or by a promise (`CatchUp').</li>
%% </ul>
%%
%% The second route is the commit index of Raft and Viewstamped Replication,
%% and section 3.3 gives the condition it rests on: an acceptor told "decided
%% in epoch e" may conclude its own entry is decided if that entry is from e,
%% where e is the epoch the value was decided in. So it is sound only while
%% a leader's commit index means "my proposals up to here were chosen in my
%% ballot, or agree with what was". A deposed leader that has not yet
%% heard it was deposed can learn a slot from the new regime and find a value
%% there that is not the one it proposed. It steps down on the spot, before
%% it can advertise a commit index covering that slot (`ConflictStepDown',
%% and `FPaxosNoConflictStepDown.cfg' is the counterexample without it).
%%
%% == What must be durable ==
%%
%% `promised' and the log. Every change to either is announced as a
%% `persist' effect in the same effect list as the reply that depends on it,
%% and `peace_server' writes before it sends. Role, commit index and machine
%% state are rebuilt on restart.
-module(peace_core).

-include("peace.hrl").

-export([init/2, handle/2]).
-export([
    id/1,
    role/1,
    leader/1,
    members/1,
    promised/1,
    commit_index/1,
    last_index/1,
    machine_state/1,
    log/1,
    decided/1,
    overview/1
]).

-export_type([core/0, event/0, effect/0, entry/0, command/0, msg/0]).

%% How many entries one `accept' or `learned' message carries at most.
-define(MAX_BATCH, 64).

%% Identifies one proposal: the ballot that first proposed it and its slot.
%% A leader answers a waiting client only when the entry applied at the slot
%% carries the tag it proposed, since another leader may have won the slot.
-type tag() :: {peace:ballot(), peace:index()}.

-type command() ::
    {'$usr', tag(), peace_machine:command()}
    | {'$noop', tag()}.

-type entry() :: {peace:ballot() | decided, command()}.

-type from() :: term().

-type kind() :: command | {query, fun((peace_machine:state()) -> term())}.

-type msg() ::
    {prepare, peace:ballot(), From :: peace:index()}
    | {promise, peace:ballot(), [{peace:index(), peace:ballot() | decided, command()}]}
    | {accept, peace:ballot(), [{peace:index(), command()}], Commit :: peace:index()}
    | {accepted, peace:ballot(), [peace:index()]}
    | {nack, peace:ballot()}
    | {catchup, From :: peace:index()}
    | {learned, [{peace:index(), command()}]}.

-type event() ::
    election_timeout
    | heartbeat_timeout
    | {command, from(), peace_machine:command()}
    | {query, from(), fun((peace_machine:state()) -> term())}
    | {msg, peace:server_id(), msg()}.

-type effect() ::
    {persist, peace_storage:batch()}
    | {send, peace:server_id(), msg()}
    | {reply, from(), term()}
    | {timer, election | heartbeat, reset | cancel}
    | {machine, peace_machine:effects()}.

-record(core, {
    id :: peace:server_id(),
    members :: [peace:server_id()],
    peers :: [peace:server_id()],
    quorum :: peace_quorum:spec(),
    machine :: peace_machine:machine(),
    mstate :: peace_machine:state(),
    role = follower :: peace:role(),
    leader :: peace:server_id() | undefined,
    %% Durable: the highest ballot promised. TLA+ `promised'.
    promised = ?NO_BALLOT :: peace:ballot(),
    %% The highest ballot seen anywhere, so the next campaign outbids it.
    seen = ?NO_BALLOT :: peace:ballot(),
    %% Durable: TLA+ `accepted'.
    log = #{} :: #{peace:index() => entry()},
    last = 0 :: non_neg_integer(),
    %% Every slot up to here is decided and applied.
    commit = 0 :: non_neg_integer(),
    %% Candidate and leader: the ballot being run.
    ballot :: peace:ballot() | undefined,
    %% Candidate: the first slot asked about, and the answers so far.
    from = 1 :: peace:index(),
    promises = #{} :: #{peace:server_id() => list()},
    %% Leader: the next free slot, who has accepted each undecided slot, and
    %% who is waiting on one.
    next = 1 :: peace:index(),
    acks = #{} :: #{peace:index() => [peace:server_id()]},
    pending = #{} :: #{peace:index() => {tag(), from(), kind()}},
    %% Whether a contradicted leader steps down. Only ever false in tests
    %% that show what the guard is for.
    conflict_step_down = true :: boolean()
}).

-opaque core() :: #core{}.

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

%% @doc A server's state on start, from its configuration and whatever its
%% storage recovered. Decided entries are applied again to rebuild the
%% machine state.
-spec init(peace:server_config(), peace_storage:stored()) -> {core(), [effect()]}.
init(Config = #{id := Id, members := Members0, machine := Machine}, Stored) ->
    Members = lists:usort(Members0),
    true = lists:member(Id, Members),
    Log = maps:get(entries, Stored, #{}),
    Promised = maps:get(promised, Stored, ?NO_BALLOT),
    C0 = #core{
        id = Id,
        members = Members,
        peers = Members -- [Id],
        quorum = maps:get(quorum, Config, majority),
        machine = Machine,
        mstate = peace_machine:init(Machine),
        promised = Promised,
        seen = Promised,
        log = Log,
        last = lists:max([0 | maps:keys(Log)]),
        conflict_step_down = not maps:get(unsafe_no_conflict_step_down, Config, false)
    },
    %% A follower has nobody waiting and performs no machine effects, so
    %% replaying the log produces none.
    {C1, []} = advance(C0),
    {C1, enter_effects(C1) ++ [{timer, election, reset}]}.

-spec handle(event(), core()) -> {core(), [effect()]}.
handle(election_timeout, C = #core{role = leader}) ->
    {C, []};
handle(election_timeout, C) ->
    campaign(C);
handle(heartbeat_timeout, C = #core{role = leader}) ->
    {C, [{timer, heartbeat, reset} | broadcast(C)]};
handle(heartbeat_timeout, C) ->
    {C, []};
handle({command, From, Command}, C) ->
    propose(From, command, {usr, Command}, C);
handle({query, From, Fun}, C) ->
    propose(From, {query, Fun}, noop, C);
handle({msg, Peer, Msg}, C = #core{peers = Peers}) ->
    case lists:member(Peer, Peers) of
        true -> msg(Msg, Peer, C);
        false -> {C, []}
    end.

-spec id(core()) -> peace:server_id().
id(#core{id = Id}) -> Id.

-spec role(core()) -> peace:role().
role(#core{role = Role}) -> Role.

-spec leader(core()) -> peace:server_id() | undefined.
leader(#core{leader = Leader}) -> Leader.

-spec members(core()) -> [peace:server_id()].
members(#core{members = Members}) -> Members.

-spec promised(core()) -> peace:ballot().
promised(#core{promised = Promised}) -> Promised.

-spec commit_index(core()) -> non_neg_integer().
commit_index(#core{commit = Commit}) -> Commit.

-spec last_index(core()) -> non_neg_integer().
last_index(#core{last = Last}) -> Last.

-spec machine_state(core()) -> peace_machine:state().
machine_state(#core{mstate = MState}) -> MState.

%% @doc The log as it should be in storage: every entry held, with the ballot
%% it was accepted in or `decided'.
-spec log(core()) -> #{peace:index() => entry()}.
log(#core{log = Log}) -> Log.

%% @doc Every entry this server knows to be decided, applied or not, as the
%% user command or `noop'.
-spec decided(core()) -> #{peace:index() => {usr, peace_machine:command()} | noop}.
decided(#core{log = Log}) ->
    maps:filtermap(
        fun
            (_I, {decided, {'$usr', _Tag, Command}}) -> {true, {usr, Command}};
            (_I, {decided, {'$noop', _Tag}}) -> {true, noop};
            (_I, _) -> false
        end,
        Log
    ).

-spec overview(core()) -> map().
overview(C = #core{}) ->
    #{
        id => C#core.id,
        role => C#core.role,
        leader => C#core.leader,
        members => C#core.members,
        quorum => C#core.quorum,
        promised => C#core.promised,
        ballot => C#core.ballot,
        commit_index => C#core.commit,
        last_index => C#core.last,
        undecided => maps:size(C#core.acks),
        pending => maps:size(C#core.pending),
        machine_state => C#core.mstate
    }.

%% ---------------------------------------------------------------------------
%% Phase 1
%% ---------------------------------------------------------------------------

%% TLA+ Phase1a, and the candidate's own Phase1b: it promises its own ballot.
campaign(C0 = #core{id = Id, promised = Promised, seen = Seen, commit = Commit, peers = Peers}) ->
    {Round, _} = max(Promised, Seen),
    Ballot = {Round + 1, Id},
    {C1, Enter} = become(candidate, C0#core{leader = undefined}),
    C2 = C1#core{
        promised = Ballot,
        seen = Ballot,
        ballot = Ballot,
        from = Commit + 1,
        promises = #{}
    },
    Effects =
        [{persist, #{promised => Ballot}}] ++
            Enter ++
            [{timer, election, reset}] ++
            [{send, Peer, {prepare, Ballot, Commit + 1}} || Peer <- Peers],
    maybe_lead(C2, Effects).

maybe_lead(
    C = #core{role = candidate, id = Id, promises = Promises, quorum = Quorum, members = Members},
    Effects
) ->
    case peace_quorum:is_phase1_quorum(Quorum, Members, [Id | maps:keys(Promises)]) of
        true ->
            {C1, Lead} = lead(C),
            {C1, Effects ++ Lead};
        false ->
            {C, Effects}
    end.

%% TLA+ Phase2a for every slot a promise mentioned, plus CatchUp for the ones
%% reported decided.
lead(C0 = #core{id = Id, ballot = Ballot, from = From, promises = Promises, log = Log0}) ->
    %% The candidate's own entries are read now, not when it started asking:
    %% it may have learned decided slots in between, and must not overwrite
    %% one with a stale report.
    Reports = lists:append([entries_from(From, Log0) | maps:values(Promises)]),
    Best = lists:foldl(fun best/2, #{}, Reports),
    Max = lists:max([From - 1, C0#core.last | maps:keys(Best)]),
    {Log, Acks, Changed} = lists:foldl(
        fun(I, {L, A, Ch}) ->
            case maps:get(I, Best, none) of
                {decided, Command} ->
                    Entry = {decided, Command},
                    case L of
                        #{I := Entry} -> {L, A, Ch};
                        _ -> {L#{I => Entry}, A, [{I, Entry} | Ch]}
                    end;
                {_Ballot, Command} ->
                    Entry = {Ballot, Command},
                    {L#{I => Entry}, A#{I => [Id]}, [{I, Entry} | Ch]};
                none ->
                    Entry = {Ballot, {'$noop', {Ballot, I}}},
                    {L#{I => Entry}, A#{I => [Id]}, [{I, Entry} | Ch]}
            end
        end,
        {Log0, #{}, []},
        lists:seq(From, Max)
    ),
    {C1, Enter} = become(leader, C0#core{
        leader = Id,
        log = Log,
        last = Max,
        next = Max + 1,
        acks = Acks,
        promises = #{},
        pending = #{}
    }),
    {C2, Settled} = settle(C1),
    Effects =
        [{persist, #{entries => lists:reverse(Changed)}} || Changed =/= []] ++
            Enter ++
            Settled ++
            [{timer, election, cancel}, {timer, heartbeat, reset}] ++
            broadcast(C2),
    {C2, Effects}.

%% Highest ballot wins; `decided' outranks every ballot.
best({I, Ballot, Command}, Acc) ->
    case Acc of
        #{I := {Held, _}} ->
            case rank(Ballot) > rank(Held) of
                true -> Acc#{I := {Ballot, Command}};
                false -> Acc
            end;
        _ ->
            Acc#{I => {Ballot, Command}}
    end.

rank(decided) -> {1, decided};
rank(Ballot) -> {0, Ballot}.

entries_from(From, Log) ->
    lists:sort([{I, Ballot, Command} || {I, {Ballot, Command}} <- maps:to_list(Log), I >= From]).

%% ---------------------------------------------------------------------------
%% Phase 2
%% ---------------------------------------------------------------------------

%% TLA+ Phase2a for a fresh slot, and the leader's own Phase2b.
propose(
    From,
    Kind,
    What,
    C0 = #core{
        role = leader,
        id = Id,
        ballot = Ballot,
        next = I,
        log = Log,
        acks = Acks,
        pending = Pending,
        peers = Peers
    }
) ->
    Tag = {Ballot, I},
    Command =
        case What of
            {usr, User} -> {'$usr', Tag, User};
            noop -> {'$noop', Tag}
        end,
    Entry = {Ballot, Command},
    C1 = C0#core{
        log = Log#{I => Entry},
        last = I,
        next = I + 1,
        acks = Acks#{I => [Id]},
        pending = Pending#{I => {Tag, From, Kind}}
    },
    {C2, Settled} = settle(C1),
    Effects =
        [{persist, #{entries => [{I, Entry}]}}] ++
            Settled ++
            [{send, Peer, {accept, Ballot, [{I, Command}], C2#core.commit}} || Peer <- Peers],
    {C2, Effects};
propose(From, _Kind, _What, C = #core{leader = Leader}) ->
    {C, [{reply, From, {error, {not_leader, Leader}}}]}.

%% The leader's heartbeat: to each peer, the undecided entries it has not
%% acknowledged, and the commit index.
broadcast(#core{ballot = Ballot, commit = Commit, peers = Peers, acks = Acks, log = Log}) ->
    Open = lists:sort(maps:to_list(Acks)),
    [
        {send, Peer,
            {accept, Ballot,
                lists:sublist(
                    [{I, command(I, Log)} || {I, Who} <- Open, not lists:member(Peer, Who)],
                    ?MAX_BATCH
                ),
                Commit}}
     || Peer <- Peers
    ].

%% TLA+ LeaderDecide: every slot a phase-2 quorum has accepted is decided.
settle(C = #core{role = leader, acks = Acks, log = Log, quorum = Quorum, members = Members}) ->
    Chosen = [
        I
     || {I, Who} <- lists:sort(maps:to_list(Acks)),
        peace_quorum:is_phase2_quorum(Quorum, Members, Who)
    ],
    case Chosen of
        [] ->
            {C, []};
        _ ->
            Entries = [{I, {decided, command(I, Log)}} || I <- Chosen],
            {C1, Applied} = advance(C#core{
                log = maps:merge(Log, maps:from_list(Entries)),
                acks = maps:without(Chosen, Acks)
            }),
            {C1, [{persist, #{entries => Entries}} | Applied]}
    end.

%% ---------------------------------------------------------------------------
%% Messages
%% ---------------------------------------------------------------------------

%% TLA+ Phase1b.
msg({prepare, Ballot, From}, Peer, C0 = #core{promised = Promised}) when Ballot > Promised ->
    {C1, Follow} = follow(C0#core{promised = Ballot, seen = max(Ballot, C0#core.seen)}, undefined),
    Promise = {promise, Ballot, entries_from(From, C1#core.log)},
    {C1, [{persist, #{promised => Ballot}}] ++ Follow ++ [{send, Peer, Promise}]};
msg({prepare, Ballot, _From}, Peer, C = #core{promised = Promised}) when Ballot < Promised ->
    {C, [{send, Peer, {nack, Promised}}]};
msg({prepare, _Ballot, _From}, _Peer, C) ->
    {C, []};
msg({promise, Ballot, Entries}, Peer, C = #core{role = candidate, ballot = Ballot}) ->
    maybe_lead(C#core{promises = (C#core.promises)#{Peer => Entries}}, []);
msg({promise, _Ballot, _Entries}, _Peer, C) ->
    {C, []};
%% Somebody has promised a ballot above the one being run here, so it cannot
%% win. Remember the ballot so the next campaign outbids it.
msg({nack, Ballot}, _Peer, C = #core{role = Role, ballot = Mine}) when
    Role =/= follower, Ballot > Mine
->
    follow(C#core{seen = max(Ballot, C#core.seen)}, undefined);
msg({nack, Ballot}, _Peer, C) ->
    {C#core{seen = max(Ballot, C#core.seen)}, []};
%% TLA+ Phase2b, then FollowerCommit for what the commit index covers.
msg({accept, Ballot = {_, Peer}, Entries, LeaderCommit}, Peer, C0 = #core{promised = Promised}) when
    Ballot >= Promised
->
    {C1, Follow} =
        case C0 of
            #core{role = follower, leader = Peer} -> {C0, [{timer, election, reset}]};
            _ -> follow(C0, Peer)
        end,
    Log0 = C1#core.log,
    %% A decided entry is never replaced, but it is still acknowledged: a
    %% leader that has not learned the slot is decided needs the answer.
    Stored = [{I, {Ballot, Command}} || {I, Command} <- Entries, not is_decided(I, Log0)],
    Log1 = maps:merge(Log0, maps:from_list(Stored)),
    {Log2, Marked} = mark(C1#core.commit + 1, LeaderCommit, Ballot, Log1, []),
    C2 = C1#core{
        promised = Ballot,
        seen = max(Ballot, C1#core.seen),
        log = Log2,
        last = lists:max([C1#core.last | [I || {I, _} <- Stored]])
    },
    {C3, Applied} = advance(C2),
    Batch0 = #{promised => Ballot, entries => lists:sort(maps:to_list(maps:from_list(Stored ++ Marked)))},
    Batch1 =
        case Ballot > Promised of
            true -> Batch0;
            false -> maps:remove(promised, Batch0)
        end,
    Batch =
        case Batch1 of
            #{entries := []} -> maps:remove(entries, Batch1);
            _ -> Batch1
        end,
    Effects =
        [{persist, Batch} || map_size(Batch) > 0] ++
            Follow ++
            Applied ++
            [{send, Peer, {accepted, Ballot, [I || {I, _} <- Entries]}} || Entries =/= []] ++
            %% Slots the leader has decided that this server cannot decide
            %% from its own log: missing, or held from an older ballot.
            [{send, Peer, {catchup, C3#core.commit + 1}} || C3#core.commit < LeaderCommit],
    {C3, Effects};
msg({accept, _Ballot, _Entries, _Commit}, Peer, C = #core{promised = Promised}) ->
    {C, [{send, Peer, {nack, Promised}}]};
msg({accepted, Ballot, Indexes}, Peer, C = #core{role = leader, ballot = Ballot, acks = Acks0}) ->
    Acks = lists:foldl(
        fun(I, A) ->
            case A of
                #{I := Who} -> A#{I := lists:usort([Peer | Who])};
                _ -> A
            end
        end,
        Acks0,
        Indexes
    ),
    settle(C#core{acks = Acks});
msg({accepted, _Ballot, _Indexes}, _Peer, C) ->
    {C, []};
msg({catchup, From}, Peer, C = #core{commit = Commit, log = Log}) when From >= 1, From =< Commit ->
    To = min(Commit, From + ?MAX_BATCH - 1),
    {C, [{send, Peer, {learned, [{I, command(I, Log)} || I <- lists:seq(From, To)]}}]};
msg({catchup, _From}, _Peer, C) ->
    {C, []};
%% TLA+ CatchUp.
msg({learned, Entries}, _Peer, C0 = #core{log = Log0, role = Role, ballot = Mine}) ->
    New = [{I, {decided, Command}} || {I, Command} <- Entries, not is_decided(I, Log0)],
    %% TLA+ Conflict: a slot was decided against this leader's own proposal,
    %% which only a later ballot can have done. Its commit index must not
    %% come to cover that slot while followers still take it to mean "the
    %% leader's proposal was chosen".
    Conflict =
        C0#core.conflict_step_down andalso Role =:= leader andalso
            lists:any(
                fun({I, {decided, Command}}) ->
                    case Log0 of
                        #{I := {Mine, Proposed}} -> Proposed =/= Command;
                        _ -> false
                    end
                end,
                New
            ),
    {C1, Follow} =
        case Conflict of
            true -> follow(C0, undefined);
            false -> {C0, []}
        end,
    Indexes = [I || {I, _} <- New],
    C2 = C1#core{
        log = maps:merge(Log0, maps:from_list(New)),
        last = lists:max([C1#core.last | Indexes]),
        acks = maps:without(Indexes, C1#core.acks)
    },
    {C3, Applied} = advance(C2),
    {C3, [{persist, #{entries => New}} || New =/= []] ++ Follow ++ Applied}.

%% TLA+ FollowerCommit: from the first uncommitted slot, mark decided every
%% entry the leader's commit index covers that is from the leader's ballot.
%% Stops at the first slot it cannot vouch for.
mark(I, LeaderCommit, Ballot, Log, Marked) when I =< LeaderCommit ->
    case Log of
        #{I := {decided, _}} ->
            mark(I + 1, LeaderCommit, Ballot, Log, Marked);
        #{I := {Ballot, Command}} ->
            Entry = {decided, Command},
            mark(I + 1, LeaderCommit, Ballot, Log#{I := Entry}, [{I, Entry} | Marked]);
        _ ->
            {Log, lists:reverse(Marked)}
    end;
mark(_I, _LeaderCommit, _Ballot, Log, Marked) ->
    {Log, lists:reverse(Marked)}.

%% ---------------------------------------------------------------------------
%% Roles
%% ---------------------------------------------------------------------------

%% Back to follower. Whoever was waiting on this server as leader is told the
%% outcome is unknown: their command may yet be chosen by a later leader.
follow(C0 = #core{role = Role, pending = Pending}, Leader) ->
    Failed = [
        {reply, From, {error, leadership_lost}}
     || {_I, {_Tag, From, _Kind}} <- lists:sort(maps:to_list(Pending))
    ],
    {C1, Enter} = become(follower, C0#core{
        leader = Leader,
        ballot = undefined,
        promises = #{},
        acks = #{},
        pending = #{}
    }),
    Effects =
        Failed ++
            Enter ++
            [{timer, heartbeat, cancel} || Role =:= leader] ++
            [{timer, election, reset}],
    {C1, Effects}.

become(Role, C = #core{role = Role}) ->
    {C, []};
become(Role, C) ->
    C1 = C#core{role = Role},
    {C1, enter_effects(C1)}.

enter_effects(#core{machine = Machine, role = Role, mstate = MState}) ->
    machine_effects(peace_machine:state_enter(Machine, Role, MState)).

machine_effects([]) -> [];
machine_effects(Effects) -> [{machine, Effects}].

%% ---------------------------------------------------------------------------
%% Applying
%% ---------------------------------------------------------------------------

%% Applies every decided entry contiguous with the commit index.
advance(C) ->
    advance(C, []).

advance(C = #core{commit = Commit, log = Log}, Acc) ->
    I = Commit + 1,
    case Log of
        #{I := {decided, Command}} ->
            {C1, Effects} = apply_command(I, Command, C#core{commit = I}),
            advance(C1, [Effects | Acc]);
        _ ->
            {C, lists:append(lists:reverse(Acc))}
    end.

apply_command(I, {'$usr', Tag, Command}, C = #core{machine = Machine, mstate = MState0, role = Role}) ->
    {MState, Reply, Effects} = peace_machine:apply(Machine, #{index => I}, Command, MState0),
    {C1, Replies} = resolve(I, Tag, Reply, C#core{mstate = MState}),
    case Role of
        leader -> {C1, Replies ++ machine_effects(Effects)};
        _ -> {C1, Replies}
    end;
apply_command(I, {'$noop', Tag}, C) ->
    resolve(I, Tag, noop, C).

%% Answers whoever is waiting on slot I, if anybody is.
resolve(I, Tag, Reply, C = #core{pending = Pending, id = Id, mstate = MState}) ->
    case maps:take(I, Pending) of
        {{Tag, From, command}, Pending1} ->
            {C#core{pending = Pending1}, [{reply, From, {ok, Reply, Id}}]};
        {{Tag, From, {query, Fun}}, Pending1} ->
            Result =
                try
                    {ok, Fun(MState), Id}
                catch
                    Class:Reason -> {error, {query_failed, Class, Reason}}
                end,
            {C#core{pending = Pending1}, [{reply, From, Result}]};
        {{_Other, From, _Kind}, Pending1} ->
            %% Another leader's value took the slot. This one's proposal was
            %% tied to it, so it will never be chosen.
            {C#core{pending = Pending1}, [{reply, From, {error, leadership_lost}}]};
        error ->
            {C, []}
    end.

is_decided(I, Log) ->
    case Log of
        #{I := {decided, _}} -> true;
        _ -> false
    end.

command(I, Log) ->
    {_, Command} = maps:get(I, Log),
    Command.
