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
%% Multi-Paxos with co-located roles and distinct quorums per phase, from
%% Howard's thesis (UCAM-CL-TR-935, in `docs/'): her sections 3.6, 3.7 and
%% 4.1. Section references below are to it, and so are the words: epoch,
%% prepare, promise, propose, accept, phase one and phase two, proposer and
%% acceptor, value, decided, learn, the sequence and its indexes, the
%% leader. Where the thesis has
%% no word, because the thing is not in it, the section says so:
%%
%% <ul>
%% <li>in the thesis: Multi-Paxos (3.6), co-located roles (3.7), NACKs (3.1),
%%   learning (3.3), revision A's quorums (4.1), proposing to a phase-two
%%   quorum (4.3.3);</li>
%% <li>not in the thesis: the pre-vote, a leader standing down for want of a
%%   quorum, the commit index, sessions, snapshots, read leases, and the way
%%   membership changes. Their names are the usual ones from Raft and
%%   Viewstamped Replication.</li>
%% </ul>
%%
%% Every server is proposer, acceptor and learner at once. An epoch is
%% `{Round, ServerId}', so it has exactly one possible leader, and a server
%% leads for as long as nobody promises a higher one.
%%
%% Phase one, once per leadership. A follower that hears nothing from a leader
%% for an election timeout picks an epoch above any it has seen and sends
%% `{prepare, Epoch, From}', where `From' is its first undecided index. An
%% acceptor that has promised nothing higher promises, and answers with every
%% log entry it holds from `From' on. With promises from a phase-one quorum the
%% candidate leads: for every index anybody reported it re-proposes the value
%% reported at the highest epoch, and fills gaps with no-ops. An acceptor
%% that has promised something higher says so, with the epoch (a NACK,
%% section 3.1), and the candidate stands down and outbids it next time.
%%
%% Before any of that, a pre-vote, which is not in the thesis. A follower whose election timeout fires
%% does not raise its epoch straight away: it asks its peers whether they
%% would promise, and they say yes only if they have lost their leader too.
%% Nothing is promised and nothing is written. Only with yes from a phase-one
%% quorum does it campaign. A server that was merely cut off therefore comes
%% back without deposing a leader everybody else is content with. This is
%% liveness only: a campaign is always safe, and `force_election' still
%% starts one unasked.
%%
%% Phase two, once per value. The leader assigns the next index and sends
%% `{propose, Epoch, Entries, Commit}'. An acceptor that has promised nothing
%% higher stores the entries and answers `{accept, Epoch, Indexes}'. The
%% value at an index is decided once a phase-two quorum has accepted it. The two quorum
%% systems only have to intersect each other; see `peace_quorum'.
%%
%% Not in the thesis: a leader keeps its election timer running and, each
%% time it fires, asks whether a phase-two quorum has answered a heartbeat since the last time. If
%% not, it can decide nothing, and it steps down so that clients stop waiting
%% on it. Also liveness only.
%%
%% Learning, the thesis's optional phase three (section 3.3, "Termination").
%% A decided entry is kept under the marker `learned' in place of an epoch,
%% and is reported that way in promises, where it outranks every epoch.
%% Entries become decided by three routes, and they are the three learning
%% actions of the TLA+ model:
%%
%% <ul>
%% <li>the leader counts a phase-two quorum (`LeaderLearn');</li>
%% <li>a follower sees its leader's commit index reach an index where its
%%   own entry is from that leader's epoch (`FollowerCommit');</li>
%% <li>anybody is told outright, by `{learned, Entries}' in answer to a
%%   `{catchup, From}', or by a promise (`CatchUp').</li>
%% </ul>
%%
%% The second route is the commit index of Raft and Viewstamped Replication,
%% and section 3.3 gives the condition it rests on: an acceptor told "decided
%% in epoch e" may conclude its own entry is decided if that entry is from e,
%% where e is the epoch the value was decided in. So it is sound only while
%% a leader's commit index means "my proposals up to here were decided in my
%% epoch, or agree with what was". A deposed leader that has not yet
%% heard it was deposed can learn what a later epoch decided at an index and
%% find it is not the value it proposed there. It steps down on the spot, before
%% it can advertise a commit index covering that index (`ConflictStepDown',
%% and `FPaxosNoConflictStepDown.cfg' is the counterexample without it).
%%
%% == Sessions ==
%%
%% Not in the thesis.
%% A client that is told nothing (a timeout, a lost leader) cannot know
%% whether its value was decided, and a retry may put it in the log twice.
%% A value submitted with a session, `{ClientId, Seq}', is applied at most
%% once however often it is decided: each server remembers, per client, the
%% highest sequence number it has applied and the reply, and a later copy of
%% the same number gets that reply without touching the machine. The table is
%% a function of the decided log, like the machine state, so every server
%% agrees on it. A client uses one sequence number at a time, increasing.
%%
%% == Snapshots ==
%%
%% Not in the thesis.
%% Every `snapshot_interval' applied indexes a server writes its machine state
%% and session table to storage and drops the log up to there. A server asked
%% to catch somebody up from an index it no longer has sends its state instead
%% (`install').
%%
%% Truncation takes away what phase one relies on: an acceptor's report of what
%% it accepted. A candidate that asks from an index the acceptor has dropped
%% would hear nothing about it, take it to be free, and could get a second
%% value decided there. So a promise carries the acceptor's snapshot index,
%% and a candidate that is behind one abandons its campaign and catches up.
%% `FPaxosNoSnapshotGuard.cfg' is the protocol without that.
%%
%% == Read leases ==
%%
%% Not in the thesis.
%% Off unless `read_lease_ms' is set. A linearizable read is otherwise
%% ordered by putting a no-op through the log. With leases a leader may
%% answer from its own state, on the strength of this: nobody else can have
%% become leader yet.
%%
%% An acceptor that accepts from a leader will not promise any other epoch,
%% and will not campaign, for the lease duration after. A new leader needs a
%% phase-one quorum of promises. So while the servers still bound to this
%% leader are such that the rest of the cluster contains no phase-one quorum,
%% there is no other leader, and nothing decided that this one does not know
%% of. That set need not be a majority, nor even a phase-two quorum: with
%% `{counting, 4, 2}' over five servers the leader and one other will do.
%%
%% Every accept carries the leader's clock and the answer returns it, so the
%% leader measures a lease from when it sent, the acceptor from when it
%% received, and the leader trusts it for a tenth less than the acceptor
%% honours it. That tenth is the assumption: clocks that run within ten per
%% cent of each other. Safety of reads depends on it and on nothing else
%% here does. A restarted acceptor has forgotten what it was bound by and
%% honours a full lease from the moment it starts. A leader reads from its
%% own state only once everything its phase one recovered has been decided
%% again. This part is not in the TLA+ model, which has no time.
%%
%% == Proposing to a phase-two quorum ==
%%
%% Off unless `propose_to' is `quorum'. The thesis, section 4.3.3: "it is
%% necessary only for the proposer to send propose messages to a phase two
%% quorum of acceptors, provided the proposer can retry with another phase
%% two quorum if an acceptor does not respond." Of the two forms it goes on
%% to sketch, this is the second: "a leader use a small fixed quorum of
%% acceptors for the phase two. The remaining acceptors would be standbys".
%%
%% The leader picks the fewest peers that make a phase-two quorum with
%% itself, preferring those that have been answering, and sends each new
%% proposal to them alone. This is where a small phase-two quorum pays in
%% messages and not only in waiting: `{counting, 4, 2}' over five sends each
%% proposal to one peer, not four. The retry: a proposal still undecided at
%% the second heartbeat after it was made goes to everybody, and whenever
%% the election timer fires the leader picks again from whoever answered.
%% Safety is untouched, since this only narrows whom a message is sent to.
%%
%% One departure. The thesis's standbys hold no copy of the value, which is
%% where it finds a saving in storage. Every peace server applies the
%% sequence to its own state machine, so here the standbys learn each
%% decision a heartbeat later, by asking. peace saves the messages and not
%% the storage. A leader that takes a snapshot while they are behind sends
%% them the snapshot.
%%
%% == Membership ==
%%
%% Not in the thesis as such. The joint configuration is Raft's. The thesis's
%% revision B (section 4.2) lets quorums differ between epochs and asks a
%% phase-one quorum of an epoch to intersect the phase-two quorums of every
%% earlier one; it does not say how a proposer learns what those were. Here
%% the log tells it.
%%
%% Who the members are and what their quorums are is decided in the log,
%% as in `formal/Reconfig.tla', and moves from one configuration to another
%% through a joint one. A leader asked to change it proposes
%% `joint(Old, New)'; while that is in force a phase-two quorum is one of each.
%% When the joint entry is decided the leader, whoever it is by then,
%% proposes `final(New)'. One change at a time.
%%
%% The configuration in force at a server is the latest such entry in its
%% log, decided or not, and failing any, the one it has applied. That is
%% what a leader counts acknowledgements against and whom it sends to.
%%
%% A candidate is held to more: a phase-one quorum of every configuration it
%% has reason to think was in force for the indexes it is asking about. That
%% is the one it has applied, every one in its own log, and every one in a
%% configuration entry that a promise reports. So a promise can raise the
%% bar, and name servers the candidate has yet to ask.
%%
%% A server started outside the configuration takes no initiative, answers
%% what it is sent, and becomes a member when a configuration naming it
%% reaches its log. One that finds itself outside a decided final
%% configuration stops campaigning, and stands down if it was leading.
%%
%% == What must be durable ==
%%
%% `promised', the log and the snapshot. Every change to either is announced as a
%% `persist' effect in the same effect list as the reply that depends on it,
%% and `peace_server' writes before it sends. Role, commit index and machine
%% state are rebuilt on restart.
-module(peace_core).

-include("peace.hrl").

-export([init/2, init/3, handle/2, handle/3]).
-export([
    id/1,
    role/1,
    leader/1,
    members/1,
    config/1,
    promised/1,
    commit_index/1,
    last_index/1,
    machine_state/1,
    log/1,
    snapshot_index/1,
    learned/1,
    overview/1
]).

-export_type([core/0, event/0, effect/0, entry/0, value/0, msg/0, session/0, snapshot/0, config/0, simple/0]).

%% How many entries one `accept' or `learned' message carries at most.
-define(MAX_BATCH, 64).

%% Identifies one proposal: the epoch that first proposed it and its index.
%% A leader answers a waiting client only when the entry applied at the index
%% carries the tag it proposed, since another leader may have won the index.
-type tag() :: {peace:epoch(), peace:index()}.

%% Members and how they form quorums.
-type simple() :: {[peace:server_id()], peace_quorum:spec()}.
-type config() :: {final, simple()} | {joint, Old :: simple(), New :: simple()}.

-type value() ::
    {'$usr', tag(), peace_machine:value()}
    | {'$cfg', tag(), config()}
    | {'$ses', tag(), session(), peace_machine:value()}
    | {'$noop', tag()}.

%% One client's one value. See "Sessions" above.
-type session() :: {ClientId :: term(), Seq :: non_neg_integer()}.

%% Per client: the last sequence number applied, what the machine answered,
%% and the index, by which the oldest session is evicted.
-type sessions() :: #{term() => {non_neg_integer(), term(), peace:index()}}.

%% What a snapshot holds: everything that is a function of the decided log.
-type snapshot() :: {peace_machine:state(), sessions(), config()}.

-type entry() :: {peace:epoch() | learned, value()}.

-type from() :: term().

-type kind() :: value | silent | {query, fun((peace_machine:state()) -> term())}.

-type msg() ::
    {prepare, peace:epoch(), From :: peace:index()}
    | {promise, peace:epoch(), [{peace:index(), peace:epoch() | learned, value()}],
        Snapshot :: non_neg_integer()}
    | {propose, peace:epoch(), [{peace:index(), value()}], Commit :: peace:index(), Stamp :: integer()}
    | {accept, peace:epoch(), [peace:index()], Stamp :: integer()}
    | {nack, peace:epoch()}
    | {prevote, peace:epoch()}
    | {prevote_ok, peace:epoch()}
    | {catchup, From :: peace:index()}
    | {learned, [{peace:index(), value()}]}
    | {install, peace:index(), snapshot()}.

-type event() ::
    election_timeout
    | force_election
    | heartbeat_timeout
    | {value, from(), peace_machine:value()}
    | {value, from(), peace_machine:value(), session() | undefined}
    | {query, from(), fun((peace_machine:state()) -> term())}
    | {reconfigure, from(), simple()}
    | {msg, peace:server_id(), msg()}.

-type effect() ::
    {persist, peace_storage:batch()}
    | {send, peace:server_id(), msg()}
    | {reply, from(), term()}
    | {timer, election | heartbeat, reset | cancel}
    | {machine, peace_machine:effects()}.

-record(core, {
    id :: peace:server_id(),
    %% The configuration as of the commit index, and the configuration
    %% entries in the log above it, by index. See "Membership".
    acfg :: config(),
    cfgs = #{} :: #{peace:index() => config()},
    %% Leader: who asked for the change under way.
    reconf :: from() | undefined,
    use_joint = true :: boolean(),
    %% Candidate: whom it has sent a prepare.
    asked = [] :: [peace:server_id()],
    machine :: peace_machine:machine(),
    mstate :: peace_machine:state(),
    role = follower :: peace:role(),
    leader :: peace:server_id() | undefined,
    %% Durable: the highest epoch promised. TLA+ `promised'.
    promised = ?NO_EPOCH :: peace:epoch(),
    %% The highest epoch seen anywhere, so the next campaign outbids it.
    seen = ?NO_EPOCH :: peace:epoch(),
    %% Durable: TLA+ `accepted'.
    log = #{} :: #{peace:index() => entry()},
    last = 0 :: non_neg_integer(),
    %% Every index up to here is decided and applied.
    commit = 0 :: non_neg_integer(),
    %% Durable: the log holds nothing at or below this index.
    snap = 0 :: non_neg_integer(),
    snapshot_interval :: pos_integer() | infinity,
    sessions = #{} :: sessions(),
    max_sessions :: pos_integer(),
    %% Candidate and leader: the epoch being run.
    epoch :: peace:epoch() | undefined,
    %% Candidate: the first index asked about, and the answers so far.
    from = 1 :: peace:index(),
    promises = #{} :: #{peace:server_id() => list()},
    %% Follower asking before it campaigns: the epoch it would use and who
    %% has said they would promise it.
    prevote :: {peace:epoch(), [peace:server_id()]} | undefined,
    %% Leader: who has answered since the election timer last fired.
    heard = [] :: [peace:server_id()],
    %% Leader, proposing to a quorum: whom new proposals go to, and the indexes that were
    %% already waiting at the last heartbeat.
    to_quorum = false :: boolean(),
    preferred = [] :: [peace:server_id()],
    waiting = [] :: [peace:index()],
    %% Leader: the next free index, who has accepted each undecided index, and
    %% who is waiting on one.
    next = 1 :: peace:index(),
    acks = #{} :: #{peace:index() => [peace:server_id()]},
    pending = #{} :: #{peace:index() => {tag(), from(), kind()}},
    %% Whether a contradicted leader steps down. Only ever false in tests
    %% that show what the guard is for.
    conflict_step_down = true :: boolean(),
    %% Likewise for a candidate that is behind an acceptor's snapshot.
    snapshot_guard = true :: boolean(),
    %% The clock, in milliseconds, as of the event being handled.
    now = 0 :: integer(),
    lease_ms :: pos_integer() | undefined,
    %% Acceptor: no promise to another epoch and no campaign before this.
    lease_until = 0 :: integer(),
    lease_fence = true :: boolean(),
    %% Leader: the latest of its own clock readings each peer has answered,
    %% and the last index its phase one recovered.
    echoes = #{} :: #{peace:server_id() => integer()},
    barrier = 0 :: non_neg_integer()
}).

-opaque core() :: #core{}.

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

%% @doc A server's state on start, from its configuration and whatever its
%% storage recovered. Decided entries are applied again to rebuild the
%% machine state.
-spec init(peace:server_config(), peace_storage:stored()) -> {core(), [effect()]}.
init(Config, Stored) ->
    init(Config, Stored, 0).

%% @doc As `init/2', with the clock, which matters only with read leases.
-spec init(peace:server_config(), peace_storage:stored(), integer()) -> {core(), [effect()]}.
init(Config = #{id := Id, members := Members0, machine := Machine}, Stored, Now) ->
    Initial = {final, {lists:usort(Members0), maps:get(quorum, Config, majority)}},
    {Snap, {MState, Sessions, ACfg}} =
        maps:get(snapshot, Stored, {0, {peace_machine:init(Machine), #{}, Initial}}),
    %% A crash between writing a snapshot and dropping what it covers leaves
    %% entries no backend is obliged to have cleaned up.
    Log = maps:filter(fun(I, _) -> I > Snap end, maps:get(entries, Stored, #{})),
    Promised = maps:get(promised, Stored, ?NO_EPOCH),
    LeaseMs = maps:get(read_lease_ms, Config, undefined),
    C0 = #core{
        id = Id,
        acfg = ACfg,
        cfgs = maps:filtermap(
            fun
                (_I, {_Epoch, {'$cfg', _Tag, Cfg}}) -> {true, Cfg};
                (_I, _Entry) -> false
            end,
            Log
        ),
        use_joint = not maps:get(unsafe_no_joint, Config, false),
        to_quorum = maps:get(propose_to, Config, all) =:= quorum,
        machine = Machine,
        mstate = MState,
        sessions = Sessions,
        max_sessions = maps:get(max_sessions, Config, ?DEFAULT_MAX_SESSIONS),
        snap = Snap,
        commit = Snap,
        snapshot_interval = maps:get(snapshot_interval, Config, ?DEFAULT_SNAPSHOT_INTERVAL),
        promised = Promised,
        seen = Promised,
        log = Log,
        last = lists:max([Snap | maps:keys(Log)]),
        conflict_step_down = not maps:get(unsafe_no_conflict_step_down, Config, false),
        snapshot_guard = not maps:get(unsafe_no_snapshot_guard, Config, false),
        now = Now,
        lease_ms = LeaseMs,
        %% Whatever lease this server granted before it stopped, it has
        %% forgotten. The longest it can have left is a whole one.
        lease_until =
            case LeaseMs of
                undefined -> Now;
                _ -> Now + LeaseMs
            end,
        lease_fence = not maps:get(unsafe_no_lease_fence, Config, false)
    },
    %% A follower has nobody waiting and performs no machine effects, so
    %% replaying the log produces none.
    {C1, []} = advance(C0),
    {C1, enter_effects(C1) ++ [{timer, election, reset}]}.

%% @doc As `handle/2', with the clock in milliseconds. Any clock that does
%% not go backwards; it is compared only with itself and, through the lease
%% margin, with the rate of other servers' clocks.
-spec handle(event(), integer(), core()) -> {core(), [effect()]}.
handle(Event, Now, C) ->
    handle(Event, C#core{now = max(Now, C#core.now)}).

-spec handle(event(), core()) -> {core(), [effect()]}.
handle(Event, C0) ->
    %% A snapshot is taken of the state an event finds, not the state it
    %% leaves: every index it covers was written as decided by an earlier
    %% event, so nothing is ever decided and dropped in one write.
    {C1, Snapshot} = maybe_snapshot(C0),
    {C2, Effects} = event(Event, C1),
    {C3, Membership} = membership(C2),
    {C3, Snapshot ++ Effects ++ Membership}.

event(election_timeout, C = #core{role = leader}) ->
    check_quorum(C);
event(election_timeout, C) ->
    prevote(C);
event(force_election, C = #core{role = leader}) ->
    {C, []};
event(force_election, C) ->
    case fenced(C) orelse not is_member(C) of
        true -> {C, []};
        false -> campaign(C)
    end;
event(heartbeat_timeout, C0 = #core{role = leader, acks = Acks, waiting = Waiting}) ->
    Open = maps:keys(Acks),
    %% An index that has waited a whole heartbeat goes to everybody.
    Late = lists:any(fun(I) -> lists:member(I, Waiting) end, Open),
    {C1, Targets} = targets(C0),
    Quiet =
        case Late of
            true -> [];
            false -> peers(C1) -- Targets
        end,
    {C1#core{waiting = Open}, [{timer, heartbeat, reset} | broadcast(C1, Quiet)]};
event(heartbeat_timeout, C) ->
    {C, []};
event({value, From, Value}, C) ->
    propose(From, value, {usr, Value}, C);
event({value, From, Value, undefined}, C) ->
    propose(From, value, {usr, Value}, C);
event({value, From, Value, Session = {_ClientId, Seq}}, C) when is_integer(Seq), Seq >= 0 ->
    propose(From, value, {ses, Session, Value}, C);
event({query, From, Fun}, C = #core{id = Id, mstate = MState}) ->
    case holds_lease(C) of
        true ->
            Result =
                try
                    {ok, Fun(MState), Id}
                catch
                    Class:Reason -> {error, {query_failed, Class, Reason}}
                end,
            {C, [{reply, From, Result}]};
        false ->
            propose(From, {query, Fun}, noop, C)
    end;
event({reconfigure, From, New}, C) ->
    reconfigure(From, New, C);
event({msg, Peer, _Msg}, C = #core{id = Peer}) ->
    {C, []};
event({msg, Peer, Msg}, C) when element(1, Msg) =:= prepare; element(1, Msg) =:= prevote ->
    %% Nobody outside the configuration gets to depose its leader. A server
    %% that was removed and has not heard is exactly who would try.
    case lists:member(Peer, members(C)) of
        true -> msg(Msg, Peer, C);
        false -> {C, []}
    end;
event({msg, Peer, Msg}, C) ->
    msg(Msg, Peer, C).

-spec id(core()) -> peace:server_id().
id(#core{id = Id}) -> Id.

-spec role(core()) -> peace:role().
role(#core{role = Role}) -> Role.

-spec leader(core()) -> peace:server_id() | undefined.
leader(#core{leader = Leader}) -> Leader.

%% @doc Every member of the configuration in force: of both, during a
%% change.
-spec members(core()) -> [peace:server_id()].
members(C) ->
    lists:usort(lists:append([Members || {Members, _Spec} <- parts(in_force(C))])).

%% @doc The configuration in force.
-spec config(core()) -> config().
config(C) -> in_force(C).

-spec promised(core()) -> peace:epoch().
promised(#core{promised = Promised}) -> Promised.

-spec commit_index(core()) -> non_neg_integer().
commit_index(#core{commit = Commit}) -> Commit.

-spec last_index(core()) -> non_neg_integer().
last_index(#core{last = Last}) -> Last.

-spec machine_state(core()) -> peace_machine:state().
machine_state(#core{mstate = MState}) -> MState.

%% @doc The log as it should be in storage: every entry held, with the epoch
%% it was accepted in or `learned'.
-spec log(core()) -> #{peace:index() => entry()}.
log(#core{log = Log}) -> Log.

%% @doc Every entry this server knows to be decided and still holds, applied
%% or not, as the user value or `noop'.
%% @doc The index of this server's snapshot, below which it has no log. 0 if
%% it has none.
-spec snapshot_index(core()) -> non_neg_integer().
snapshot_index(#core{snap = Snap}) -> Snap.

-spec learned(core()) -> #{peace:index() => {usr, peace_machine:value()} | {cfg, config()} | noop}.
learned(#core{log = Log}) ->
    maps:filtermap(
        fun
            (_I, {learned, {'$usr', _Tag, Value}}) -> {true, {usr, Value}};
            (_I, {learned, {'$ses', _Tag, _Session, Value}}) -> {true, {usr, Value}};
            (_I, {learned, {'$noop', _Tag}}) -> {true, noop};
            (_I, {learned, {'$cfg', _Tag, Cfg}}) -> {true, {cfg, Cfg}};
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
        members => members(C),
        config => in_force(C),
        promised => C#core.promised,
        epoch => C#core.epoch,
        commit_index => C#core.commit,
        snapshot_index => C#core.snap,
        propose_to =>
            case C#core.to_quorum of
                true -> quorum;
                false -> all
            end,
        preferred => C#core.preferred,
        sessions => maps:size(C#core.sessions),
        last_index => C#core.last,
        undecided => maps:size(C#core.acks),
        pending => maps:size(C#core.pending),
        machine_state => C#core.mstate
    }.

%% ---------------------------------------------------------------------------
%% Phase one
%% ---------------------------------------------------------------------------

%% Bound by a lease to the leader it last accepted from.
fenced(#core{lease_ms = undefined}) -> false;
fenced(#core{lease_fence = false}) -> false;
fenced(#core{now = Now, lease_until = Until}) -> Now < Until.

%% Whether this leader may answer a read from its own state. See "Read
%% leases" above.
holds_lease(#core{role = leader, lease_ms = LeaseMs, commit = Commit, barrier = Barrier} = C) when
    is_integer(LeaseMs), Commit >= Barrier
->
    #core{id = Id, now = Now, echoes = Echoes} = C,
    Trust = LeaseMs - max(1, LeaseMs div 10),
    Bound = [Peer || {Peer, Stamp} <- maps:to_list(Echoes), Now < Stamp + Trust],
    %% During a change, of each configuration: a rival may know of only one.
    lists:all(
        fun({Members, Spec}) ->
            not peace_quorum:is_phase_one_quorum(Spec, Members, Members -- [Id | Bound])
        end,
        parts(in_force(C))
    );
holds_lease(_C) ->
    false.

%% Not in the model, which lets anybody campaign at any time.
prevote(C = #core{}) ->
    case fenced(C) orelse not is_member(C) of
        true -> {C, [{timer, election, reset}]};
        false -> prevote1(C)
    end.

prevote1(C0 = #core{id = Id, promised = Promised, seen = Seen}) ->
    {Round, _} = max(Promised, Seen),
    Epoch = {Round + 1, Id},
    Peers = peers(C0),
    case q1([Id], C0) of
        true ->
            %% Nobody to ask.
            campaign(C0);
        false ->
            %% Having timed out, this server has no leader, and will say so
            %% to anybody else who asks.
            {C1, Enter} = become(follower, C0#core{
                leader = undefined, epoch = undefined, promises = #{}, prevote = {Epoch, []}
            }),
            {C1, Enter ++ [{timer, election, reset}] ++ [{send, Peer, {prevote, Epoch}} || Peer <- Peers]}
    end.

%% A leader that a phase-two quorum has stopped answering cannot decide
%% anything. Better to say so than to hold clients until they time out.
check_quorum(C = #core{id = Id, heard = Heard}) ->
    case q2([Id | Heard], C) of
        true ->
            %% Whoever answered is who to count on next.
            C1 = prefer(C),
            {C1#core{heard = []}, [{timer, election, reset}]};
        false ->
            follow(C, undefined)
    end.

%% Whom a new proposal is sent to: everybody, or with `propose_to => quorum' the preferred
%% peers, picked again if the configuration has moved under them.
targets(C = #core{to_quorum = false}) ->
    {C, peers(C)};
targets(C = #core{id = Id, preferred = Preferred}) ->
    Peers = peers(C),
    case Preferred -- Peers =:= [] andalso q2([Id | Preferred], C) of
        true ->
            {C, Preferred};
        false ->
            C1 = prefer(C),
            {C1, C1#core.preferred}
    end.

%% The fewest peers that make a phase-two quorum with this server, those that
%% have answered lately first. Found by trying every set of each size in
%% turn, because quorum systems that are not a count, like a grid, have
%% quorums a greedy choice walks past. Beyond a dozen peers that is too
%% many sets, and any quorum will do: peers are dropped from everybody
%% for as long as a quorum is left.
prefer(C = #core{to_quorum = false}) ->
    C;
prefer(C = #core{id = Id, heard = Heard}) ->
    Peers = peers(C),
    Order = [P || P <- Peers, lists:member(P, Heard)] ++ [P || P <- Peers, not lists:member(P, Heard)],
    Enough = fun(Set) -> q2([Id | Set], C) end,
    Decided =
        case length(Order) =< 12 of
            true -> smallest(0, Order, Enough);
            false -> prune(lists:reverse(Order), Order, Enough)
        end,
    C#core{preferred = lists:sort(Decided)}.

%% With no quorum to be had, everybody: the index will wait in any case.
smallest(Size, Order, _Enough) when Size > length(Order) ->
    Order;
smallest(Size, Order, Enough) ->
    case choose(Size, Order, [], Enough) of
        {ok, Set} -> Set;
        none -> smallest(Size + 1, Order, Enough)
    end.

choose(0, _Rest, Acc, Enough) ->
    case Enough(Acc) of
        true -> {ok, Acc};
        false -> none
    end;
choose(_Size, [], _Acc, _Enough) ->
    none;
choose(Size, [Peer | Rest], Acc, Enough) ->
    case choose(Size - 1, Rest, [Peer | Acc], Enough) of
        {ok, Set} -> {ok, Set};
        none -> choose(Size, Rest, Acc, Enough)
    end.

prune([], Kept, _Enough) ->
    Kept;
prune([Peer | Rest], Kept, Enough) ->
    case Enough(Kept -- [Peer]) of
        true -> prune(Rest, Kept -- [Peer], Enough);
        false -> prune(Rest, Kept, Enough)
    end.

%% TLA+ Prepare, and the candidate's own Promise: it promises its own epoch.
campaign(C0 = #core{id = Id, promised = Promised, seen = Seen, commit = Commit}) ->
    %% Everybody in any configuration this server knows of. Promises may
    %% name more.
    Peers = lists:usort(lists:append([M || {M, _} <- bar(C0)])) -- [Id],
    {Round, _} = max(Promised, Seen),
    Epoch = {Round + 1, Id},
    {C1, Enter} = become(candidate, C0#core{leader = undefined}),
    C2 = C1#core{
        promised = Epoch,
        seen = Epoch,
        epoch = Epoch,
        from = Commit + 1,
        promises = #{},
        prevote = undefined,
        asked = Peers
    },
    Effects =
        [{persist, #{promised => Epoch}}] ++
            Enter ++
            [{timer, election, reset}] ++
            [{send, Peer, {prepare, Epoch, Commit + 1}} || Peer <- Peers],
    maybe_lead(C2, Effects).

%% TLA+ Elected: a phase-one quorum of every configuration in the bar.
maybe_lead(C = #core{role = candidate, id = Id, promises = Promises, epoch = Epoch, from = From}, Effects) ->
    Bar = bar(C),
    Promised = [Id | maps:keys(Promises)],
    case lists:all(fun({Members, Spec}) -> peace_quorum:is_phase_one_quorum(Spec, Members, Promised) end, Bar) of
        true ->
            {C1, Lead} = lead(C),
            {C1, Effects ++ Lead};
        false ->
            %% A promise may have named servers nobody has asked yet.
            New = (lists:usort(lists:append([M || {M, _} <- Bar])) -- [Id]) -- C#core.asked,
            {C#core{asked = C#core.asked ++ New}, Effects ++ [{send, Peer, {prepare, Epoch, From}} || Peer <- New]}
    end.

%% TLA+ Bar: every configuration this server has reason to think was in
%% force for the indexes it is asking about. What it has applied, what is in
%% its own log, and, as a candidate, what the promises report.
bar(C = #core{acfg = ACfg, cfgs = Cfgs, promises = Promises, from = From}) ->
    Reported =
        case C#core.role of
            candidate ->
                [Cfg || Entries <- maps:values(Promises), {I, _Epoch, {'$cfg', _Tag, Cfg}} <- Entries, I >= From];
            _ ->
                []
        end,
    lists:usort(lists:append([parts(Cfg) || Cfg <- [ACfg | maps:values(Cfgs)] ++ Reported])).

parts({final, Simple}) -> [Simple];
parts({joint, Old, New}) -> [Old, New].

%% The configuration in force: the latest entry above the commit index, or
%% what has been applied.
in_force(#core{acfg = ACfg, cfgs = Cfgs}) when map_size(Cfgs) =:= 0 ->
    ACfg;
in_force(#core{cfgs = Cfgs}) ->
    maps:get(lists:max(maps:keys(Cfgs)), Cfgs).

peers(C = #core{id = Id}) ->
    members(C) -- [Id].

is_member(C = #core{id = Id}) ->
    lists:member(Id, members(C)).

%% During a change, a quorum of each.
q1(Set, C) ->
    lists:all(fun({Members, Spec}) -> peace_quorum:is_phase_one_quorum(Spec, Members, Set) end, parts(in_force(C))).

q2(Set, C) ->
    lists:all(fun({Members, Spec}) -> peace_quorum:is_phase_two_quorum(Spec, Members, Set) end, parts(in_force(C))).

%% Keeps `cfgs' in step with entries written to the log.
note(Entries, C = #core{cfgs = Cfgs0}) ->
    Cfgs = lists:foldl(
        fun
            ({I, {_Epoch, {'$cfg', _Tag, Cfg}}}, Acc) -> Acc#{I => Cfg};
            ({I, _Entry}, Acc) -> maps:remove(I, Acc)
        end,
        Cfgs0,
        Entries
    ),
    C#core{cfgs = Cfgs}.

%% TLA+ Propose for every index a promise mentioned, plus CatchUp for the ones
%% reported decided.
lead(C0 = #core{id = Id, epoch = Epoch, from = From0, promises = Promises, log = Log0}) ->
    %% The candidate's own entries are read now, not when it started asking:
    %% it may have learned decided indexes in between, and must not overwrite
    %% one with a stale report. What it has applied since it asked needs no
    %% proposal, and may already be under a snapshot.
    From = max(From0, C0#core.commit + 1),
    Reports = [R || R = {I, _, _} <- lists:append([entries_from(From, Log0) | maps:values(Promises)]), I >= From],
    Best = lists:foldl(fun best/2, #{}, Reports),
    Max = lists:max([From - 1, C0#core.last | maps:keys(Best)]),
    {Log, Acks, Changed} = lists:foldl(
        fun(I, {L, A, Ch}) ->
            case maps:get(I, Best, none) of
                {learned, Value} ->
                    Entry = {learned, Value},
                    case L of
                        #{I := Entry} -> {L, A, Ch};
                        _ -> {L#{I => Entry}, A, [{I, Entry} | Ch]}
                    end;
                {_Epoch, Value} ->
                    Entry = {Epoch, Value},
                    {L#{I => Entry}, A#{I => [Id]}, [{I, Entry} | Ch]};
                none ->
                    Entry = {Epoch, {'$noop', {Epoch, I}}},
                    {L#{I => Entry}, A#{I => [Id]}, [{I, Entry} | Ch]}
            end
        end,
        {Log0, #{}, []},
        lists:seq(From, Max)
    ),
    {C1, Enter} = become(leader, (note(Changed, C0))#core{
        leader = Id,
        log = Log,
        last = Max,
        next = Max + 1,
        acks = Acks,
        promises = #{},
        pending = #{},
        heard = [],
        preferred = [],
        waiting = [],
        echoes = #{},
        barrier = Max
    }),
    {C2, Settled} = settle(C1),
    Effects =
        [{persist, #{entries => lists:reverse(Changed)}} || Changed =/= []] ++
            Enter ++
            Settled ++
            [{timer, election, reset}, {timer, heartbeat, reset}] ++
            broadcast(C2, []),
    {C2, Effects}.

%% Highest epoch wins; `learned' outranks every epoch.
best({I, Epoch, Value}, Acc) ->
    case Acc of
        #{I := {Held, _}} ->
            case rank(Epoch) > rank(Held) of
                true -> Acc#{I := {Epoch, Value}};
                false -> Acc
            end;
        _ ->
            Acc#{I => {Epoch, Value}}
    end.

rank(learned) -> {1, learned};
rank(Epoch) -> {0, Epoch}.

entries_from(From, Log) ->
    lists:sort([{I, Epoch, Value} || {I, {Epoch, Value}} <- maps:to_list(Log), I >= From]).

%% ---------------------------------------------------------------------------
%% Phase two
%% ---------------------------------------------------------------------------

%% TLA+ Propose for a fresh index, and the leader's own Accept.
propose(
    From,
    Kind,
    What,
    C0 = #core{
        role = leader,
        id = Id,
        epoch = Epoch,
        next = I,
        log = Log,
        acks = Acks,
        pending = Pending
    }
) ->
    Tag = {Epoch, I},
    Value =
        case What of
            {usr, User} -> {'$usr', Tag, User};
            {ses, Session, User} -> {'$ses', Tag, Session, User};
            {cfg, Cfg} -> {'$cfg', Tag, Cfg};
            noop -> {'$noop', Tag}
        end,
    Entry = {Epoch, Value},
    C1 = (note([{I, Entry}], C0))#core{
        log = Log#{I => Entry},
        last = I,
        next = I + 1,
        acks = Acks#{I => [Id]},
        pending = Pending#{I => {Tag, From, Kind}}
    },
    {C2, Settled} = settle(C1),
    %% Of the configuration in force with this entry in the log: a joint
    %% entry goes to the servers it adds.
    {C3, Targets} = targets(C2),
    Effects =
        [{persist, #{entries => [{I, Entry}]}}] ++
            Settled ++
            [{send, Peer, {propose, Epoch, [{I, Value}], C3#core.commit, C3#core.now}} || Peer <- Targets],
    {C3, Effects};
propose(From, _Kind, _What, C = #core{leader = Leader}) ->
    {C, [{reply, From, {error, {not_leader, Leader}}}]}.

%% The leader's heartbeat: to each peer the commit index and, unless it is
%% one of `Quiet', the undecided entries it has not acknowledged.
broadcast(C = #core{epoch = Epoch, commit = Commit, acks = Acks, log = Log, now = Now}, Quiet) ->
    Peers = peers(C),
    Open = lists:sort(maps:to_list(Acks)),
    [
        {send, Peer,
            {propose, Epoch,
                case lists:member(Peer, Quiet) of
                    true ->
                        [];
                    false ->
                        lists:sublist(
                            [{I, value(I, Log)} || {I, Who} <- Open, not lists:member(Peer, Who)],
                            ?MAX_BATCH
                        )
                end,
                Commit, Now}}
     || Peer <- Peers
    ].

%% TLA+ LeaderLearn: every index a phase-two quorum has accepted is decided.
settle(C = #core{role = leader, acks = Acks, log = Log}) ->
    %% Against the configuration in force now, whichever was when the index
    %% was proposed. See formal/Reconfig.tla, `LeaderLearn'.
    Decided = [I || {I, Who} <- lists:sort(maps:to_list(Acks)), q2(Who, C)],
    case Decided of
        [] ->
            {C, []};
        _ ->
            Entries = [{I, {learned, value(I, Log)}} || I <- Decided],
            {C1, Applied} = advance(C#core{
                log = maps:merge(Log, maps:from_list(Entries)),
                acks = maps:without(Decided, Acks)
            }),
            {C1, [{persist, #{entries => Entries}} | Applied]}
    end.

%% ---------------------------------------------------------------------------
%% Messages
%% ---------------------------------------------------------------------------

%% TLA+ Promise.
msg({prepare, Epoch, From}, Peer, C0 = #core{promised = Promised}) when Epoch > Promised ->
    case fenced(C0) of
        %% Silence, as if the message were lost: a refusal would teach the
        %% candidate nothing it can use before the lease runs out.
        true -> {C0, []};
        false -> promise(Epoch, From, Peer, C0)
    end;
msg({prepare, Epoch, _From}, Peer, C = #core{promised = Promised}) when Epoch < Promised ->
    {C, [{send, Peer, {nack, Promised}}]};
msg({prepare, _Epoch, _From}, _Peer, C) ->
    {C, []};
msg(Msg, Peer, C) ->
    msg1(Msg, Peer, C).

promise(Epoch, From, Peer, C0) ->
    {C1, Follow} = follow(C0#core{promised = Epoch, seen = max(Epoch, C0#core.seen)}, undefined),
    Promise = {promise, Epoch, entries_from(From, C1#core.log), C1#core.snap},
    {C1, [{persist, #{promised => Epoch}}] ++ Follow ++ [{send, Peer, Promise}]}.

%% The acceptor has dropped indexes this candidate asked about, so its report
%% is silent on them. They are decided; what they hold the candidate can only
%% find out by catching up, and until it has it must not lead.
msg1({promise, Epoch, _Entries, Snap}, Peer, C0 = #core{role = candidate, epoch = Epoch, from = From}) when
    Snap >= From, C0#core.snapshot_guard
->
    {C1, Follow} = follow(C0, undefined),
    {C1, Follow ++ [{send, Peer, {catchup, C1#core.commit + 1}}]};
msg1({promise, Epoch, Entries, _Snap}, Peer, C = #core{role = candidate, epoch = Epoch}) ->
    maybe_lead(C#core{promises = (C#core.promises)#{Peer => Entries}}, []);
msg1({promise, _Epoch, _Entries, _Snap}, _Peer, C) ->
    {C, []};
%% Somebody has promised an epoch above the one being run here, so it cannot
%% win. Remember the epoch so the next campaign outbids it.
msg1({nack, Epoch}, _Peer, C = #core{role = Role, epoch = Mine}) when
    Role =/= follower, Epoch > Mine
->
    follow(C#core{seen = max(Epoch, C#core.seen)}, undefined);
msg1({nack, Epoch}, _Peer, C) ->
    {C#core{seen = max(Epoch, C#core.seen)}, []};
%% Would this server promise `Epoch'? Only if it could, and only if it has
%% no leader of its own to lose.
msg1({prevote, Epoch}, Peer, C = #core{promised = Promised, leader = undefined, role = Role}) when
    Epoch > Promised, Role =/= leader
->
    case fenced(C) of
        true -> {C, []};
        false -> {C, [{send, Peer, {prevote_ok, Epoch}}]}
    end;
msg1({prevote, Epoch}, Peer, C = #core{promised = Promised}) when Epoch < Promised ->
    {C, [{send, Peer, {nack, Promised}}]};
msg1({prevote, _Epoch}, _Peer, C) ->
    {C, []};
msg1({prevote_ok, Epoch}, Peer, C = #core{prevote = {Epoch, Granted0}, id = Id}) ->
    Granted = lists:usort([Peer | Granted0]),
    case q1([Id | Granted], C) of
        true ->
            case fenced(C) of
                true -> {C#core{prevote = undefined}, []};
                false -> campaign(C)
            end;
        false ->
            {C#core{prevote = {Epoch, Granted}}, []}
    end;
msg1({prevote_ok, _Epoch}, _Peer, C) ->
    {C, []};
%% TLA+ Accept, then FollowerCommit for what the commit index covers.
msg1({propose, Epoch = {_, Peer}, Entries, LeaderCommit, Stamp}, Peer, C0 = #core{promised = Promised}) when
    Epoch >= Promised
->
    {C1, Follow} =
        case C0 of
            #core{role = follower, leader = Peer} -> {C0, [{timer, election, reset}]};
            _ -> follow(C0, Peer)
        end,
    Log0 = C1#core.log,
    %% A decided entry is never replaced, but it is still acknowledged: a
    %% leader that has not learned the index is decided needs the answer.
    %% Nor is anything stored at an index the snapshot covers: it is decided
    %% too, and only looks empty.
    Stored = [
        {I, {Epoch, Value}}
     || {I, Value} <- Entries, I > C1#core.snap, not is_learned(I, Log0)
    ],
    Log1 = maps:merge(Log0, maps:from_list(Stored)),
    {Log2, Marked} = mark(C1#core.commit + 1, LeaderCommit, Epoch, Log1, []),
    C2 = (note(Stored, C1))#core{
        promised = Epoch,
        seen = max(Epoch, C1#core.seen),
        %% From now, by this server's clock: later than the leader counts
        %% from, which is when it sent.
        lease_until =
            case C1#core.lease_ms of
                undefined -> C1#core.lease_until;
                LeaseMs -> max(C1#core.lease_until, C1#core.now + LeaseMs)
            end,
        log = Log2,
        last = lists:max([C1#core.last | [I || {I, _} <- Stored]])
    },
    {C3, Applied} = advance(C2),
    Batch0 = #{promised => Epoch, entries => lists:sort(maps:to_list(maps:from_list(Stored ++ Marked)))},
    Batch1 =
        case Epoch > Promised of
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
            %% Sent even when there was nothing to accept: it is how the
            %% leader knows this server still hears it.
            [{send, Peer, {accept, Epoch, [I || {I, _} <- Entries], Stamp}}] ++
            %% Indexes the leader has decided that this server cannot decide
            %% from its own log: missing, or held from an older epoch.
            [{send, Peer, {catchup, C3#core.commit + 1}} || C3#core.commit < LeaderCommit],
    {C3, Effects};
msg1({propose, _Epoch, _Entries, _Commit, _Stamp}, Peer, C = #core{promised = Promised}) ->
    {C, [{send, Peer, {nack, Promised}}]};
msg1({accept, Epoch, Indexes, Stamp}, Peer, C = #core{role = leader, epoch = Epoch, acks = Acks0}) ->
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
    Echoes = maps:update_with(Peer, fun(Old) -> max(Old, Stamp) end, Stamp, C#core.echoes),
    settle(C#core{acks = Acks, heard = lists:usort([Peer | C#core.heard]), echoes = Echoes});
msg1({accept, _Epoch, _Indexes, _Stamp}, _Peer, C) ->
    {C, []};
msg1({catchup, From}, Peer, C = #core{commit = Commit, snap = Snap}) when From >= 1, From =< Snap ->
    %% The entries are gone. The state they led to is not, and the state as
    %% of the commit index is as good as the state as of the snapshot.
    {C, [{send, Peer, {install, Commit, {C#core.mstate, C#core.sessions, C#core.acfg}}}]};
msg1({catchup, From}, Peer, C = #core{commit = Commit, log = Log}) when From >= 1, From =< Commit ->
    To = min(Commit, From + ?MAX_BATCH - 1),
    {C, [{send, Peer, {learned, [{I, value(I, Log)} || I <- lists:seq(From, To)]}}]};
msg1({catchup, _From}, _Peer, C) ->
    {C, []};
%% TLA+ CatchUp.
msg1({install, Index, _Snapshot}, _Peer, C = #core{commit = Commit}) when Index =< Commit ->
    {C, []};
msg1({install, Index, {MState, Sessions, ACfg}}, _Peer, C0 = #core{role = Role, log = Log0}) ->
    %% A leader cannot tell whether its own proposals below `Index' are what
    %% was decided there. By the argument at `learned' below, it has been
    %% deposed.
    {C1, Follow} =
        case Role of
            leader -> follow(C0, undefined);
            _ -> {C0, []}
        end,
    C2 = C1#core{
        mstate = MState,
        sessions = Sessions,
        acfg = ACfg,
        cfgs = maps:filter(fun(I, _) -> I > Index end, C1#core.cfgs),
        commit = Index,
        snap = Index,
        log = maps:filter(fun(I, _) -> I > Index end, Log0),
        last = max(C1#core.last, Index)
    },
    {C3, Applied} = advance(C2),
    {C3, [{persist, #{snapshot => {Index, {MState, Sessions, ACfg}}}}] ++ Follow ++ Applied};
msg1({learned, Entries}, _Peer, C0 = #core{log = Log0, role = Role, epoch = Mine, snap = Snap}) ->
    New = [{I, {learned, Value}} || {I, Value} <- Entries, I > Snap, not is_learned(I, Log0)],
    %% TLA+ Conflict. A leader should learn nothing this way that it did not
    %% propose itself: every undecided index it knows of holds its own
    %% proposal, and a lower epoch cannot have decided an index beyond those
    %% without its phase-one quorum having reported it. So an index decided with
    %% another value, or a decided index it has not proposed in at all, is the
    %% work of a later epoch. Its commit index must not come to cover such
    %% an index while followers still take it to mean "the leader's proposal
    %% was decided", and it must not go on to propose in one. It steps down.
    Conflict =
        C0#core.conflict_step_down andalso Role =:= leader andalso
            lists:any(
                fun({I, {learned, Value}}) ->
                    case Log0 of
                        #{I := {Mine, Value}} -> false;
                        _ -> true
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
    C2 = (note(New, C1))#core{
        log = maps:merge(Log0, maps:from_list(New)),
        last = lists:max([C1#core.last | Indexes]),
        acks = maps:without(Indexes, C1#core.acks)
    },
    {C3, Applied} = advance(C2),
    {C3, [{persist, #{entries => New}} || New =/= []] ++ Follow ++ Applied}.

%% TLA+ FollowerCommit: from the first uncommitted index, mark decided every
%% entry the leader's commit index covers that is from the leader's epoch.
%% Stops at the first index it cannot vouch for.
mark(I, LeaderCommit, Epoch, Log, Marked) when I =< LeaderCommit ->
    case Log of
        #{I := {learned, _}} ->
            mark(I + 1, LeaderCommit, Epoch, Log, Marked);
        #{I := {Epoch, Value}} ->
            Entry = {learned, Value},
            mark(I + 1, LeaderCommit, Epoch, Log#{I := Entry}, [{I, Entry} | Marked]);
        _ ->
            {Log, lists:reverse(Marked)}
    end;
mark(_I, _LeaderCommit, _Epoch, Log, Marked) ->
    {Log, lists:reverse(Marked)}.

%% ---------------------------------------------------------------------------
%% Roles
%% ---------------------------------------------------------------------------

%% Back to follower. Whoever was waiting on this server as leader is told the
%% outcome is unknown: their value may yet be decided by a later leader.
follow(C0 = #core{role = Role, pending = Pending}, Leader) ->
    Failed =
        [
            {reply, From, {error, leadership_lost}}
         || {_I, {_Tag, From, Kind}} <- lists:sort(maps:to_list(Pending)), Kind =/= silent
        ] ++
            [{reply, From, {error, leadership_lost}} || From <- [C0#core.reconf], From =/= undefined],
    {C1, Enter} = become(follower, C0#core{
        leader = Leader,
        epoch = undefined,
        promises = #{},
        prevote = undefined,
        asked = [],
        reconf = undefined,
        acks = #{},
        pending = #{},
        heard = [],
        echoes = #{}
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
        #{I := {learned, Value}} ->
            {C1, Effects} = apply_value(I, Value, C#core{commit = I}),
            advance(C1, [Effects | Acc]);
        _ ->
            {C, lists:append(lists:reverse(Acc))}
    end.

apply_value(I, {'$usr', Tag, Value}, C = #core{machine = Machine, mstate = MState0, role = Role}) ->
    {MState, Reply, Effects} = peace_machine:apply(Machine, #{index => I}, Value, MState0),
    {C1, Replies} = resolve(I, Tag, Reply, C#core{mstate = MState}),
    case Role of
        leader -> {C1, Replies ++ machine_effects(Effects)};
        _ -> {C1, Replies}
    end;
apply_value(I, {'$ses', Tag, {ClientId, Seq}, Value}, C = #core{sessions = Sessions}) ->
    case Sessions of
        #{ClientId := {Seq, Reply, _At}} ->
            %% Decided twice, applied once: the answer it got the first time.
            resolve(I, Tag, Reply, C);
        #{ClientId := {Later, _Reply, _At}} when Later > Seq ->
            %% An old copy, arriving after the client moved on.
            resolve(I, Tag, {'$error', {session_superseded, Later}}, C);
        _ ->
            #core{machine = Machine, mstate = MState0, role = Role} = C,
            {MState, Reply, Effects} = peace_machine:apply(Machine, #{index => I}, Value, MState0),
            C1 = C#core{
                mstate = MState,
                sessions = evict(Sessions#{ClientId => {Seq, Reply, I}}, C#core.max_sessions)
            },
            {C2, Replies} = resolve(I, Tag, Reply, C1),
            case Role of
                leader -> {C2, Replies ++ machine_effects(Effects)};
                _ -> {C2, Replies}
            end
    end;
apply_value(I, {'$cfg', Tag, Cfg}, C = #core{cfgs = Cfgs}) ->
    %% Applied, so no longer an entry above the commit index.
    resolve(I, Tag, ok, C#core{acfg = Cfg, cfgs = maps:remove(I, Cfgs)});
apply_value(I, {'$noop', Tag}, C) ->
    resolve(I, Tag, noop, C).

%% By index, which every server agrees on, so every server evicts the same
%% client. A client evicted while it still has a value in flight loses
%% its protection for that value.
evict(Sessions, Max) when map_size(Sessions) =< Max ->
    Sessions;
evict(Sessions, _Max) ->
    {_At, Oldest} = lists:min([{At, ClientId} || {ClientId, {_Seq, _Reply, At}} <- maps:to_list(Sessions)]),
    maps:remove(Oldest, Sessions).

%% ---------------------------------------------------------------------------
%% Membership
%% ---------------------------------------------------------------------------

reconfigure(From, _New, C = #core{role = Role, leader = Leader}) when Role =/= leader ->
    {C, [{reply, From, {error, {not_leader, Leader}}}]};
reconfigure(From, {Members0, Spec}, C = #core{id = Id, acfg = ACfg, cfgs = Cfgs, use_joint = UseJoint}) ->
    New = {lists:usort(Members0), Spec},
    case {ACfg, map_size(Cfgs), peace_quorum:validate(Spec, Members0)} of
        {{final, New}, 0, _} ->
            {C, [{reply, From, {ok, ok, Id}}]};
        {{final, Old}, 0, ok} when UseJoint ->
            %% TLA+ MayIntroduce, `joint'. Whoever asked is answered when
            %% the final entry is applied.
            {C1, Effects} = propose(undefined, silent, {cfg, {joint, Old, New}}, C),
            {C1#core{reconf = From}, Effects};
        {{final, _Old}, 0, ok} ->
            propose(From, value, {cfg, {final, New}}, C);
        {_, _, {error, Reason}} ->
            {C, [{reply, From, {error, {invalid_quorum, Reason}}}]};
        _ ->
            {C, [{reply, From, {error, reconfiguration_in_progress}}]}
    end.

%% What a leader owes the configuration, looked at after every event.
membership(C = #core{role = leader, id = Id, acfg = ACfg, cfgs = Cfgs}) when map_size(Cfgs) =:= 0 ->
    case ACfg of
        {joint, _Old, New} ->
            %% TLA+ MayIntroduce, `final': the joint entry is decided, and
            %% nothing has followed it. Whichever leader finds things so.
            Kind =
                case C#core.reconf of
                    undefined -> silent;
                    _ -> value
                end,
            {C1, Effects} = propose(C#core.reconf, Kind, {cfg, {final, New}}, C),
            {C1#core{reconf = undefined}, Effects};
        {final, {Members, _Spec}} ->
            case lists:member(Id, Members) of
                true -> {C, []};
                %% It has seen its own removal through. Somebody who is
                %% still a member leads from here, and is told first that
                %% the change is decided: until one of them knows, they
                %% cannot elect anybody without the servers they replaced.
                false ->
                    {C1, Follow} = follow(C, undefined),
                    {C1, broadcast(C, []) ++ Follow}
            end
    end;
membership(C) ->
    {C, []}.

%% ---------------------------------------------------------------------------
%% Snapshots
%% ---------------------------------------------------------------------------

maybe_snapshot(C = #core{commit = Commit, snap = Snap, snapshot_interval = Interval, log = Log}) when
    is_integer(Interval), Commit - Snap >= Interval
->
    C1 = C#core{snap = Commit, log = maps:filter(fun(I, _) -> I > Commit end, Log)},
    {C1, [{persist, #{snapshot => {Commit, {C#core.mstate, C#core.sessions, C#core.acfg}}}}]};
maybe_snapshot(C) ->
    {C, []}.

%% Answers whoever is waiting on index I, if anybody is.
resolve(I, Tag, Reply, C = #core{pending = Pending, id = Id, mstate = MState}) ->
    case maps:take(I, Pending) of
        {{Tag, From, value}, Pending1} ->
            Answer =
                case Reply of
                    {'$error', Reason} -> {error, Reason};
                    _ -> {ok, Reply, Id}
                end,
            {C#core{pending = Pending1}, [{reply, From, Answer}]};
        {{Tag, _From, silent}, Pending1} ->
            {C#core{pending = Pending1}, []};
        {{_Other, _From, silent}, Pending1} ->
            {C#core{pending = Pending1}, []};
        {{Tag, From, {query, Fun}}, Pending1} ->
            Result =
                try
                    {ok, Fun(MState), Id}
                catch
                    Class:Reason -> {error, {query_failed, Class, Reason}}
                end,
            {C#core{pending = Pending1}, [{reply, From, Result}]};
        {{_Other, From, _Kind}, Pending1} ->
            %% Another leader's value took the index. This one's proposal was
            %% tied to it, so it will never be decided.
            {C#core{pending = Pending1}, [{reply, From, {error, leadership_lost}}]};
        error ->
            {C, []}
    end.

is_learned(I, Log) ->
    case Log of
        #{I := {learned, _}} -> true;
        _ -> false
    end.

value(I, Log) ->
    {_, Value} = maps:get(I, Log),
    Value.
