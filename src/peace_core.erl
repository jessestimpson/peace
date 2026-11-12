%% @doc The Flexible Paxos protocol, written as a pure function.
%%
%% `handle/2' takes an event and a state. It returns the new state and a
%% list of effects. `handle/2' does not send messages, does not write to
%% storage and does not read a clock. `peace_server' performs those actions
%% when it executes the effects. This design has two results:
%%
%% <ul>
%% <li>The protocol can be tested without processes.</li>
%% <li>The code stays close to `formal/FlexiblePaxos.tla'. That model is the
%%   same protocol without the effects.</li>
%% </ul>
%%
%% Comments in this module name the TLA+ action that each clause corresponds
%% to.
%%
%% == The protocol ==
%%
%% The protocol is Multi-Paxos with co-located roles and a distinct quorum
%% system for each phase. It comes from Howard's thesis (UCAM-CL-TR-935, in
%% `docs/'), sections 3.6, 3.7 and 4.1. Section references in this module
%% refer to the thesis. This module uses the terms of the thesis: epoch,
%% prepare, promise, propose, accept, phase one, phase two, proposer,
%% acceptor, value, decided, learn, sequence, index and leader. Some
%% features of this module are not in the thesis, so the thesis has no term
%% for them. The text about each such feature says that the feature is not
%% in the thesis.
%%
%% These features are in the thesis:
%%
%% <ul>
%% <li>Multi-Paxos (section 3.6)</li>
%% <li>co-located roles (section 3.7)</li>
%% <li>NACKs (section 3.1)</li>
%% <li>learning (section 3.3)</li>
%% <li>the quorums of revision A (section 4.1)</li>
%% <li>proposing to a phase-two quorum (section 4.3.3)</li>
%% </ul>
%%
%% These features are not in the thesis:
%%
%% <ul>
%% <li>the pre-vote</li>
%% <li>a leader that steps down because it has no quorum</li>
%% <li>the commit index</li>
%% <li>sessions</li>
%% <li>snapshots</li>
%% <li>read leases</li>
%% <li>the method for changing membership</li>
%% </ul>
%%
%% The names of the features that are not in the thesis are the usual names
%% from Raft and Viewstamped Replication.
%%
%% Every server is a proposer, an acceptor and a learner at the same time.
%% An epoch is `{Round, ServerId}'. Therefore exactly one server can be the
%% leader of a given epoch. A server remains the leader for as long as no
%% server promises a higher epoch.
%%
%% Phase one runs once for each leadership:
%%
%% <ol>
%% <li>A follower receives nothing from a leader for one election
%%   timeout.</li>
%% <li>The follower picks an epoch higher than every epoch it has seen. It
%%   sends `{prepare, Epoch, From}'. `From' is the first undecided index of
%%   the follower. The follower is now a candidate.</li>
%% <li>An acceptor promises the epoch only if the epoch is higher than the
%%   epoch that the acceptor has promised. The acceptor replies with every
%%   log entry that it holds at index `From' or above.</li>
%% <li>An acceptor that has promised a higher epoch replies with that epoch.
%%   This reply is a NACK (section 3.1). The candidate then abandons its
%%   campaign. The next campaign of that server uses an epoch higher than
%%   the epoch in the NACK.</li>
%% <li>An acceptor that has promised exactly this epoch ignores the prepare
%%   and sends no reply.</li>
%% <li>An acceptor that is bound by a read lease also ignores the prepare
%%   and sends no reply. See "Read leases".</li>
%% <li>When the candidate has promises from a phase-one quorum, the
%%   candidate becomes the leader. For every index that any server reported,
%%   the leader proposes again the value that was reported with the highest
%%   epoch. The leader fills gaps with no-ops.</li>
%% </ol>
%%
%% A pre-vote runs before phase one. The pre-vote is not in the thesis. A
%% follower whose election timeout fires does not raise its epoch
%% immediately. The pre-vote works as follows:
%%
%% <ol>
%% <li>The follower asks its peers whether they would promise.</li>
%% <li>A peer answers yes only if the peer has also lost its leader.</li>
%% <li>No server promises anything and no server writes anything during the
%%   pre-vote.</li>
%% <li>The follower starts a campaign only when it has a yes answer from a
%%   phase-one quorum.</li>
%% </ol>
%%
%% As a result, a server that was only disconnected from the other servers
%% reconnects without deposing a leader that all the other servers still
%% accept. The pre-vote affects liveness only. It does not affect safety,
%% because a campaign is always safe. `force_election' still starts a
%% campaign without a pre-vote.
%%
%% Phase two runs once for each value:
%%
%% <ol>
%% <li>The leader assigns the next index to the value and sends
%%   `{propose, Epoch, Entries, Commit, Stamp}'. `Commit' is the commit
%%   index of the leader. `Stamp' is the clock reading of the leader.</li>
%% <li>An acceptor that has not promised a higher epoch stores the entries
%%   and replies `{accept, Epoch, Indexes, Stamp}'. `Stamp' is the clock
%%   reading from the propose message.</li>
%% <li>The value at an index is decided when a phase-two quorum has accepted
%%   it.</li>
%% </ol>
%%
%% The phase-one quorum system and the phase-two quorum system only have to
%% intersect each other. See `peace_quorum'.
%%
%% The following feature is not in the thesis. A leader keeps its election
%% timer running. Each time the election timer fires, the leader checks
%% whether a phase-two quorum has answered a heartbeat since the timer last
%% fired. If no phase-two quorum has answered, the leader cannot decide any
%% value. The leader then steps down, so that clients stop waiting for it.
%% This feature also affects liveness only. It does not affect safety.
%%
%% Learning is the optional phase three of the thesis (section 3.3,
%% "Termination"). A server stores a decided entry with the marker `learned'
%% in place of an epoch. A promise reports a decided entry with the same
%% marker. In a promise, `learned' ranks above every epoch. An entry becomes
%% decided in one of three ways. The three ways are the three learning
%% actions of the TLA+ model:
%%
%% <ul>
%% <li>`LeaderLearn': the leader counts accepts from a phase-two
%%   quorum.</li>
%% <li>`FollowerCommit': a follower sees that the commit index of its leader
%%   has reached an index, and the entry of the follower at that index is
%%   from the epoch of that leader.</li>
%% <li>`CatchUp': a server is told directly that the entry is decided. The
%%   server is told by `{learned, Entries}' in reply to `{catchup, From}',
%%   or by a promise.</li>
%% </ul>
%%
%% `FollowerCommit' is the commit index of Raft and Viewstamped Replication.
%% Section 3.3 gives the condition that `FollowerCommit' depends on: an
%% acceptor that is told "decided in epoch e" may conclude that its own
%% entry is decided if that entry is from e, where e is the epoch in which
%% the value was decided. Therefore `FollowerCommit' is sound only while the
%% commit index of a leader means "my proposals up to here were decided in
%% my epoch, or agree with what was".
%%
%% A leader can be deposed and not yet know that it was deposed. Such a
%% leader can learn the value that a later epoch decided at an index. That
%% value can differ from the value that the leader proposed at that index.
%% In that case the leader steps down immediately. The leader steps down
%% before it can send a commit index that covers that index. This rule is
%% `ConflictStepDown'. `FPaxosNoConflictStepDown.cfg' is the counterexample
%% without this rule.
%%
%% == Sessions ==
%%
%% Sessions are not in the thesis.
%%
%% A client that receives no reply (for example after a timeout or after
%% the leader is lost) cannot know whether its value was decided. If the
%% client retries, the value can enter the log twice. A value submitted with
%% a session, `{ClientId, Seq}', is applied at most once, however many times
%% it is decided. Each server records, for each client, the highest sequence
%% number that the server has applied and the reply to that value. When a
%% later copy with the same sequence number is decided, the server returns
%% the recorded reply and does not apply the value to the machine. The
%% session table is a function of the decided log, as the machine state is.
%% Therefore every server has the same session table. A client uses one
%% sequence number at a time, and its sequence numbers increase.
%%
%% == Snapshots ==
%%
%% Snapshots are not in the thesis.
%%
%% Each time a server has applied `snapshot_interval' indexes, the server
%% writes its machine state, its session table and the configuration that
%% it has applied to storage, and removes the log up to the last applied
%% index. When a server is asked to catch another
%% server up from an index that it no longer holds, it sends its state
%% instead (`install').
%%
%% Removing log entries removes information that phase one relies on: the
%% report by an acceptor of the values that it accepted. Without a guard,
%% the following could happen:
%%
%% <ol>
%% <li>A candidate asks from an index that the acceptor has removed.</li>
%% <li>The promise contains nothing about that index.</li>
%% <li>The candidate treats the index as free.</li>
%% <li>The candidate gets a second value decided at that index.</li>
%% </ol>
%%
%% To prevent this, a promise carries the snapshot index of the acceptor. A
%% candidate that is behind that snapshot index abandons its campaign and
%% catches up. `FPaxosNoSnapshotGuard.cfg' is the protocol without this
%% guard.
%%
%% == Read leases ==
%%
%% Read leases are not in the thesis.
%%
%% Read leases are off unless `read_lease_ms' is set. Without read leases, a
%% linearizable read is ordered by deciding a no-op in the log. With read
%% leases, a leader may answer a read from its own state. This is correct
%% because no other server can have become the leader yet. The argument is
%% as follows:
%%
%% <ul>
%% <li>An acceptor that accepts from a leader does not promise any other
%%   epoch and does not campaign for the lease duration after the
%%   accept.</li>
%% <li>A new leader needs promises from a phase-one quorum.</li>
%% <li>Some servers are still bound by a lease to this leader. While the
%%   servers that are not bound contain no phase-one quorum, there is no
%%   other leader, and no value has been decided that this leader does not
%%   know of.</li>
%% </ul>
%%
%% The set of bound servers does not have to be a majority. It does not have
%% to be a phase-two quorum either. For example, with `{counting, 4, 2}'
%% over five servers, the leader and one other server are enough.
%%
%% Every propose message carries the clock reading of the leader, and the
%% accept message returns that reading. The lease is measured as follows:
%%
%% <ul>
%% <li>The leader measures a lease from the time it sent the message.</li>
%% <li>The acceptor measures a lease from the time it received the
%%   message.</li>
%% <li>The leader trusts a lease for one tenth less time than the acceptor
%%   honours it.</li>
%% </ul>
%%
%% That one tenth is the assumption about clocks: the clocks of the servers
%% run within ten per cent of each other. The safety of reads depends on
%% this assumption. Nothing else in this module depends on it.
%%
%% A restarted acceptor no longer knows which lease it was bound by.
%% Therefore it honours a full lease from the moment it starts. A leader
%% reads from its own state only after every entry that its phase one
%% recovered has been decided again. Read leases are not in the TLA+ model,
%% because the model has no time. The margin is tested in `peace_core_tests'
%% with clocks a tenth apart and with clocks a quarter apart.
%%
%% == Proposing to a phase-two quorum ==
%%
%% This feature is off unless `propose_to' is `quorum'. The thesis says in
%% section 4.3.3: "it is necessary only for the proposer to send propose
%% messages to a phase two quorum of acceptors, provided the proposer can
%% retry with another phase two quorum if an acceptor does not respond." The
%% thesis then sketches two forms. This module implements the second form:
%% "a leader use a small fixed quorum of acceptors for the phase two. The
%% remaining acceptors would be standbys".
%%
%% The leader picks the smallest set of peers that forms a phase-two quorum
%% together with the leader. The leader prefers peers that have been
%% answering. The leader sends each new proposal only to the picked peers.
%% With this feature, a small phase-two quorum reduces the number of
%% messages as well as the waiting time. For example, `{counting, 4, 2}'
%% over five servers sends each proposal to one peer instead of four peers.
%%
%% The retry works as follows:
%%
%% <ul>
%% <li>A proposal that is still undecided at the second heartbeat after it
%%   was made is sent to every peer.</li>
%% <li>Each time the election timer fires, the leader picks the peers again
%%   from the peers that answered.</li>
%% </ul>
%%
%% This feature does not affect safety, because it only reduces the set of
%% servers that a message is sent to.
%%
%% This module departs from the thesis in one way. The standbys in the
%% thesis hold no copy of the value. That is how the thesis saves storage.
%% Every peace server applies the sequence to its own state machine.
%% Therefore the standbys in peace learn each decision one heartbeat later,
%% by asking for it. peace saves messages. peace does not save storage. If a
%% leader takes a snapshot while the standbys are behind, the leader sends
%% the snapshot to the standbys.
%%
%% == Membership ==
%%
%% This method for changing membership is not in the thesis. The joint
%% configuration comes from Raft. Revision B of the thesis (section 4.2)
%% allows quorums to differ between epochs. Revision B requires a phase-one
%% quorum of an epoch to intersect the phase-two quorums of every earlier
%% epoch. The thesis does not say how a proposer learns what the quorums of
%% the earlier epochs were. In peace, the proposer learns them from the log.
%%
%% The members and their quorums are decided in the log, as in
%% `formal/Reconfig.tla'. The servers move from one configuration to another
%% configuration through a joint configuration:
%%
%% <ol>
%% <li>A leader that is asked to change the configuration proposes
%%   `joint(Old, New)'. While the joint configuration is in force, a
%%   phase-two quorum is a phase-two quorum of `Old' together with a
%%   phase-two quorum of `New'.</li>
%% <li>When the joint entry is decided, the leader proposes `final(New)'.
%%   The leader at that time can be a different server from the leader that
%%   proposed the joint entry.</li>
%% </ol>
%%
%% Only one change is in progress at a time.
%%
%% The configuration in force at a server is the latest configuration entry
%% in the log of that server, whether that entry is decided or not. If the
%% log holds no configuration entry, the configuration in force is the
%% configuration that the server has applied. A leader counts
%% acknowledgements against the configuration in force and sends messages to
%% the members of the configuration in force.
%%
%% A candidate needs more than the configuration in force. A candidate needs
%% a phase-one quorum of every configuration that may have been in force for
%% the indexes that the candidate asks about. Those configurations are:
%%
%% <ul>
%% <li>the configuration that the candidate has applied;</li>
%% <li>every configuration in the log of the candidate;</li>
%% <li>every configuration in a configuration entry that a promise
%%   reports.</li>
%% </ul>
%%
%% Therefore a promise can add a configuration that the candidate needs a
%% phase-one quorum of. That configuration can name servers that the
%% candidate has not yet sent a prepare to.
%%
%% A server that is started outside the configuration does not start any
%% action itself. It only replies to the messages that it receives. It
%% becomes a member when a configuration that names it reaches its log. A
%% server that is outside a decided final configuration stops campaigning.
%% If that server was the leader, it steps down.
%%
%% == What must be durable ==
%%
%% Three things must be durable: `promised', the log and the snapshot. Every
%% change to any of them is announced as a `persist' effect. The `persist'
%% effect is in the same effect list as the reply that depends on the
%% change, and `peace_server' writes before it sends. The one exception is
%% the `propose' message of a leader. See `perform/2' in `peace_server'.
%% The role, the commit index and the machine state are rebuilt on restart.
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

%% The maximum number of entries that one `propose' message from
%% `broadcast/2' carries, and the maximum number of entries that one
%% `learned' message carries.
-define(MAX_BATCH, 64).

%% A tag identifies one proposal. A tag is the epoch that first proposed the
%% value and the index of the value. A leader replies to a waiting client
%% only when the entry applied at the index carries the tag that the leader
%% proposed. The check is needed because the value of another leader may
%% have been decided at that index.
-type tag() :: {peace:epoch(), peace:index()}.

%% The members and the specification of their quorums.
-type simple() :: {[peace:server_id()], peace_quorum:spec()}.
-type config() :: {final, simple()} | {joint, Old :: simple(), New :: simple()}.

-type value() ::
    {'$usr', tag(), peace_machine:value()}
    | {'$cfg', tag(), config()}
    | {'$ses', tag(), session(), peace_machine:value()}
    | {'$noop', tag()}.

%% A session identifies one value of one client. See "Sessions" above.
-type session() :: {ClientId :: term(), Seq :: non_neg_integer()}.

%% The session table. For each client it holds:
%%   - the last sequence number applied;
%%   - the reply of the machine to that value;
%%   - the index of that value. Eviction removes the session with the
%%     lowest index.
-type sessions() :: #{term() => {non_neg_integer(), term(), peace:index()}}.

%% The contents of a snapshot. A snapshot holds everything that is a
%% function of the decided log.
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
    %% `acfg' is the configuration as of the commit index. `cfgs' holds the
    %% configuration entries in the log above the commit index, keyed by
    %% index. See "Membership".
    acfg :: config(),
    cfgs = #{} :: #{peace:index() => config()},
    %% Leader: the caller that asked for the configuration change that is
    %% in progress.
    reconf :: from() | undefined,
    use_joint = true :: boolean(),
    %% Candidate: the servers that it has sent a prepare to.
    asked = [] :: [peace:server_id()],
    machine :: peace_machine:machine(),
    mstate :: peace_machine:state(),
    role = follower :: peace:role(),
    leader :: peace:server_id() | undefined,
    %% Durable. The highest epoch promised. This field is TLA+ `promised'.
    promised = ?NO_EPOCH :: peace:epoch(),
    %% The highest epoch that this server has seen from any source. The
    %% next campaign uses an epoch higher than this epoch.
    seen = ?NO_EPOCH :: peace:epoch(),
    %% Durable. This field is TLA+ `accepted'.
    log = #{} :: #{peace:index() => entry()},
    last = 0 :: non_neg_integer(),
    %% Every index up to and including this index is decided and applied.
    commit = 0 :: non_neg_integer(),
    %% Durable. The log holds no entry at or below this index.
    snap = 0 :: non_neg_integer(),
    snapshot_interval :: pos_integer() | infinity,
    sessions = #{} :: sessions(),
    max_sessions :: pos_integer(),
    %% Candidate and leader: the epoch that this server is running.
    epoch :: peace:epoch() | undefined,
    %% Candidate: `from' is the first index that it asked about. `promises'
    %% holds the promises received so far.
    from = 1 :: peace:index(),
    promises = #{} :: #{peace:server_id() => list()},
    %% Follower during a pre-vote: the epoch that it would use, and the
    %% servers that have answered that they would promise that epoch.
    prevote :: {peace:epoch(), [peace:server_id()]} | undefined,
    %% Leader: the servers that have answered since the election timer last
    %% fired.
    heard = [] :: [peace:server_id()],
    %% Leader, when proposing to a quorum: `preferred' holds the peers that
    %% new proposals are sent to. `waiting' holds the indexes that were
    %% already undecided at the last heartbeat.
    to_quorum = false :: boolean(),
    preferred = [] :: [peace:server_id()],
    waiting = [] :: [peace:index()],
    %% Leader: `next' is the next free index. `acks' holds, for each
    %% undecided index, the servers that have accepted it. `pending' holds,
    %% for each index, the caller that is waiting for it.
    next = 1 :: peace:index(),
    acks = #{} :: #{peace:index() => [peace:server_id()]},
    pending = #{} :: #{peace:index() => {tag(), from(), kind()}},
    %% Whether a leader steps down when it learns a decided value that
    %% differs from its own proposal. This field is false only in tests
    %% that show why the step-down is needed.
    conflict_step_down = true :: boolean(),
    %% Whether a candidate that is behind the snapshot of an acceptor
    %% abandons its campaign. This field is false only in tests that show
    %% why the guard is needed.
    snapshot_guard = true :: boolean(),
    %% The clock reading, in milliseconds, at the event being handled.
    now = 0 :: integer(),
    lease_ms :: pos_integer() | undefined,
    %% Acceptor: before this time, this server does not promise another
    %% epoch and does not campaign.
    lease_until = 0 :: integer(),
    lease_fence = true :: boolean(),
    %% Leader: `echoes' holds, for each peer, the latest clock reading of
    %% the leader that the peer has returned. `barrier' is the last index
    %% that the phase one of this leader recovered.
    echoes = #{} :: #{peace:server_id() => integer()},
    barrier = 0 :: non_neg_integer()
}).

-opaque core() :: #core{}.

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

%% @doc Returns the state of a server on start. The state is built from the
%% configuration of the server and from the data that its storage recovered.
%% Decided entries are applied again to rebuild the machine state.
-spec init(peace:server_config(), peace_storage:stored()) -> {core(), [effect()]}.
init(Config, Stored) ->
    init(Config, Stored, 0).

%% @doc The same as `init/2', with the clock reading. The clock reading
%% matters only when read leases are on.
-spec init(peace:server_config(), peace_storage:stored(), integer()) -> {core(), [effect()]}.
init(Config = #{id := Id, members := Members0, machine := Machine}, Stored, Now) ->
    Initial = {final, {lists:usort(Members0), maps:get(quorum, Config, majority)}},
    {Snap, {MState, Sessions, ACfg}} =
        maps:get(snapshot, Stored, {0, {peace_machine:init(Machine), #{}, Initial}}),
    %% A crash can happen after a snapshot is written and before the entries
    %% that the snapshot covers are removed. No storage backend is required
    %% to have removed those entries, so they are removed here.
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
        use_joint = not ?PLANTED(unsafe_no_joint, Config),
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
        conflict_step_down = not ?PLANTED(unsafe_no_conflict_step_down, Config),
        snapshot_guard = not ?PLANTED(unsafe_no_snapshot_guard, Config),
        now = Now,
        lease_ms = LeaseMs,
        %% This server no longer knows which lease it granted before it
        %% stopped. The longest time that such a lease can have left is one
        %% full lease duration.
        lease_until =
            case LeaseMs of
                undefined -> Now;
                _ -> Now + LeaseMs
            end,
        lease_fence = not ?PLANTED(unsafe_no_lease_fence, Config)
    },
    %% A follower has no waiting callers and performs no machine effects.
    %% Therefore replaying the log produces no effects.
    {C1, []} = advance(C0),
    {C1, enter_effects(C1) ++ [{timer, election, reset}]}.

%% @doc The same as `handle/2', with the clock reading in milliseconds. Any
%% clock that does not go backwards can be used. The clock is compared only
%% with itself and, through the lease margin, with the rate of the clocks of
%% other servers.
-spec handle(event(), integer(), core()) -> {core(), [effect()]}.
handle(Event, Now, C) ->
    handle(Event, C#core{now = max(Now, C#core.now)}).

-spec handle(event(), core()) -> {core(), [effect()]}.
handle(Event, C0) ->
    %% The snapshot is taken of the state before the event is handled, not
    %% of the state after the event is handled. Every index that the
    %% snapshot covers was written as decided by an earlier event. Therefore
    %% no index is decided and removed in the same write.
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
    %% If an index has been undecided for a whole heartbeat interval, the
    %% undecided entries are sent to every peer.
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
    %% A server outside the configuration must not be able to depose the
    %% leader. A server that was removed and has not learned of its removal
    %% is the kind of server that sends such a prepare or prevote.
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

%% @doc Returns every member of the configuration in force. During a
%% configuration change, this is every member of both configurations.
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

%% @doc Returns the log as it should be in storage. The log holds every
%% entry that this server holds. Each entry has the epoch that it was
%% accepted in, or `learned'.
-spec log(core()) -> #{peace:index() => entry()}.
log(#core{log = Log}) -> Log.

%% @doc Returns the index of the snapshot of this server. The server holds
%% no log entry at or below this index. Returns 0 if the server has no
%% snapshot.
-spec snapshot_index(core()) -> non_neg_integer().
snapshot_index(#core{snap = Snap}) -> Snap.

%% @doc Returns every entry that this server knows to be decided and still
%% holds, whether the entry is applied or not. Each entry is returned as
%% `{usr, Value}' for a user value, `{cfg, Config}' for a configuration
%% entry, or `noop'.
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

%% Whether this server is bound by a lease to the leader that it last
%% accepted from.
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
    %% During a configuration change, the check is made for each
    %% configuration, because a rival candidate may know of only one of
    %% the two configurations.
    lists:all(
        fun({Members, Spec}) ->
            not peace_quorum:is_phase_one_quorum(Spec, Members, Members -- [Id | Bound])
        end,
        parts(in_force(C))
    );
holds_lease(_C) ->
    false.

%% The pre-vote is not in the TLA+ model. The model lets any server campaign
%% at any time.
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
            %% This server alone is a phase-one quorum, so there is no peer
            %% to ask.
            campaign(C0);
        false ->
            %% This server has timed out, so it has no leader. `leader' is
            %% cleared, so that this server answers accordingly when another
            %% server sends it a prevote.
            {C1, Enter} = become(follower, C0#core{
                leader = undefined, epoch = undefined, promises = #{}, prevote = {Epoch, []}
            }),
            {C1, Enter ++ [{timer, election, reset}] ++ [{send, Peer, {prevote, Epoch}} || Peer <- Peers]}
    end.

%% A leader cannot decide any value when no phase-two quorum answers it. In
%% that case the leader steps down, so that waiting clients receive an error
%% and do not wait until they time out.
check_quorum(C = #core{id = Id, heard = Heard}) ->
    case q2([Id | Heard], C) of
        true ->
            %% The preferred peers are picked again from the peers that
            %% answered.
            C1 = prefer(C),
            {C1#core{heard = []}, [{timer, election, reset}]};
        false ->
            follow(C, undefined)
    end.

%% Returns the peers that a new proposal is sent to. By default these are
%% all peers. With `propose_to => quorum' these are the preferred peers. The
%% preferred peers are picked again if the configuration has changed so that
%% they are no longer all peers, or no longer form a phase-two quorum with
%% this server.
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

%% Picks the smallest set of peers that forms a phase-two quorum together
%% with this server. Peers that have answered recently are tried first. The
%% function tries every set of each size in turn. A greedy choice is not
%% enough, because a quorum system that is not a count, such as a grid, has
%% quorums that a greedy choice does not find. With more than twelve peers
%% there are too many sets to try. In that case any quorum is accepted: the
%% function starts with all peers and removes peers one at a time for as
%% long as the remaining peers still form a quorum.
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

%% If no set of peers forms a quorum, the result is all peers. The index
%% stays undecided whichever peers are picked.
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

%% TLA+ Prepare, together with the Promise of the candidate itself. The
%% candidate promises its own epoch.
campaign(C0 = #core{id = Id, promised = Promised, seen = Seen, commit = Commit}) ->
    %% The prepare is sent to every server in any configuration that this
    %% server knows of. Promises may name more servers.
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

%% TLA+ Elected. The candidate needs a phase-one quorum of every
%% configuration that `bar/1' returns.
maybe_lead(C = #core{role = candidate, id = Id, promises = Promises, epoch = Epoch, from = From}, Effects) ->
    Bar = bar(C),
    Promised = [Id | maps:keys(Promises)],
    case lists:all(fun({Members, Spec}) -> peace_quorum:is_phase_one_quorum(Spec, Members, Promised) end, Bar) of
        true ->
            {C1, Lead} = lead(C),
            {C1, Effects ++ Lead};
        false ->
            %% A promise may have named servers that have not been sent a
            %% prepare yet.
            New = (lists:usort(lists:append([M || {M, _} <- Bar])) -- [Id]) -- C#core.asked,
            {C#core{asked = C#core.asked ++ New}, Effects ++ [{send, Peer, {prepare, Epoch, From}} || Peer <- New]}
    end.

%% TLA+ Bar. Returns every configuration that may have been in force for the
%% indexes that this server asks about:
%%   - the configuration that this server has applied;
%%   - every configuration in the log of this server;
%%   - if this server is a candidate, every configuration that the promises
%%     report.
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

%% Returns the configuration in force. This is the latest configuration
%% entry above the commit index. If there is no such entry, it is the
%% configuration that has been applied.
in_force(#core{acfg = ACfg, cfgs = Cfgs}) when map_size(Cfgs) =:= 0 ->
    ACfg;
in_force(#core{cfgs = Cfgs}) ->
    maps:get(lists:max(maps:keys(Cfgs)), Cfgs).

peers(C = #core{id = Id}) ->
    members(C) -- [Id].

is_member(C = #core{id = Id}) ->
    lists:member(Id, members(C)).

%% During a configuration change, the set must contain a quorum of each
%% configuration.
q1(Set, C) ->
    lists:all(fun({Members, Spec}) -> peace_quorum:is_phase_one_quorum(Spec, Members, Set) end, parts(in_force(C))).

q2(Set, C) ->
    lists:all(fun({Members, Spec}) -> peace_quorum:is_phase_two_quorum(Spec, Members, Set) end, parts(in_force(C))).

%% Updates `cfgs' to match the entries that are written to the log.
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

%% TLA+ Propose for every index that a promise mentioned, and CatchUp for
%% the indexes that were reported as decided.
lead(C0 = #core{id = Id, epoch = Epoch, from = From0, promises = Promises, log = Log0}) ->
    %% The entries of the candidate itself are read now, not at the time
    %% the candidate sent the prepare. The candidate may have learned
    %% decided indexes since that time. The candidate must not overwrite a
    %% decided index with an older report. The indexes that the candidate
    %% has applied since it sent the prepare need no proposal. Those indexes
    %% may already be covered by a snapshot.
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

%% Keeps, for each index, the report with the highest epoch. `learned' ranks
%% above every epoch.
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

%% TLA+ Propose for a new index, together with the Accept of the leader
%% itself.
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
    %% A configuration entry changes the configuration in force, and with it
    %% the phase-two quorums of every open index. Any other entry can make
    %% only its own index decided.
    {C2, Settled} =
        case What of
            {cfg, _} -> settle(C1);
            _ -> settle([I], C1)
        end,
    %% The targets are taken from the configuration that is in force with
    %% this entry in the log. Therefore a joint entry is sent to the servers
    %% that it adds.
    {C3, Targets} = targets(C2),
    Effects =
        [{persist, #{entries => [{I, Entry}]}}] ++
            Settled ++
            [{send, Peer, {propose, Epoch, [{I, Value}], C3#core.commit, C3#core.now}} || Peer <- Targets],
    {C3, Effects};
propose(From, _Kind, _What, C = #core{leader = Leader}) ->
    {C, [{reply, From, {error, {not_leader, Leader}}}]}.

%% The heartbeat of the leader. The leader sends the commit index to each
%% peer. To each peer that is not in `Quiet', the leader also sends the
%% undecided entries that the peer has not acknowledged.
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

%% TLA+ LeaderLearn. Every index that a phase-two quorum has accepted is
%% decided.
settle(C = #core{role = leader, acks = Acks}) ->
    settle(maps:keys(Acks), C).

%% The same as `settle/1', for the given indexes only. The caller passes the
%% indexes whose acknowledgements have changed. The cost of an event then
%% does not grow with the number of open indexes.
settle(Indexes, C = #core{role = leader, acks = Acks, log = Log}) ->
    %% The quorum is checked against the configuration in force now. It
    %% does not matter which configuration was in force when the index was
    %% proposed. See formal/Reconfig.tla, `LeaderLearn'.
    Decided = [I || I <- lists:usort(Indexes), is_map_key(I, Acks), q2(maps:get(I, Acks), C)],
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
        %% This server sends no reply, as if the message were lost. A
        %% refusal would give the candidate no information that it could
        %% use before the lease expires.
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

%% The acceptor has removed indexes that this candidate asked about, so the
%% promise contains nothing about those indexes. Those indexes are decided.
%% The candidate can learn their values only by catching up. The candidate
%% must not lead until it has caught up.
msg1({promise, Epoch, _Entries, Snap}, Peer, C0 = #core{role = candidate, epoch = Epoch, from = From}) when
    Snap >= From, C0#core.snapshot_guard
->
    {C1, Follow} = follow(C0, undefined),
    {C1, Follow ++ [{send, Peer, {catchup, C1#core.commit + 1}}]};
msg1({promise, Epoch, Entries, _Snap}, Peer, C = #core{role = candidate, epoch = Epoch}) ->
    maybe_lead(C#core{promises = (C#core.promises)#{Peer => Entries}}, []);
msg1({promise, _Epoch, _Entries, _Snap}, _Peer, C) ->
    {C, []};
%% Another server has promised an epoch higher than the epoch that this
%% server is running, so the epoch of this server cannot win. This server
%% records the higher epoch, so that its next campaign uses an epoch above
%% it.
msg1({nack, Epoch}, _Peer, C = #core{role = Role, epoch = Mine}) when
    Role =/= follower, Epoch > Mine
->
    follow(C#core{seen = max(Epoch, C#core.seen)}, undefined);
msg1({nack, Epoch}, _Peer, C) ->
    {C#core{seen = max(Epoch, C#core.seen)}, []};
%% A prevote asks whether this server would promise `Epoch'. This server
%% answers yes only if it could promise `Epoch' and it has no leader.
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
%% TLA+ Accept, followed by FollowerCommit for the indexes that the commit
%% index covers.
msg1({propose, Epoch = {_, Peer}, Entries, LeaderCommit, Stamp}, Peer, C0 = #core{promised = Promised}) when
    Epoch >= Promised
->
    {C1, Follow} =
        case C0 of
            #core{role = follower, leader = Peer} -> {C0, [{timer, election, reset}]};
            _ -> follow(C0, Peer)
        end,
    Log0 = C1#core.log,
    %% A decided entry is never replaced. It is still acknowledged, because
    %% a leader that has not learned that the index is decided needs the
    %% acknowledgement. No entry is stored at an index that the snapshot
    %% covers. Such an index is also decided. It has no entry in the log
    %% only because the snapshot removed the entry.
    Stored = [
        {I, {Epoch, Value}}
     || {I, Value} <- Entries, I > C1#core.snap, not is_learned(I, Log0)
    ],
    Log1 = maps:merge(Log0, maps:from_list(Stored)),
    {Log2, Marked} = mark(C1#core.commit + 1, LeaderCommit, Epoch, Log1, []),
    C2 = (note(Stored, C1))#core{
        promised = Epoch,
        seen = max(Epoch, C1#core.seen),
        %% The lease runs from now, by the clock of this server. This is
        %% later than the time that the leader counts from, which is the
        %% time the leader sent the message.
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
            %% The accept is sent even when there was nothing to accept. The
            %% leader uses the accept to know that this server still
            %% receives its messages.
            [{send, Peer, {accept, Epoch, [I || {I, _} <- Entries], Stamp}}] ++
            %% The catchup is sent when the leader has decided indexes that
            %% this server cannot mark as decided from its own log. The
            %% entries at those indexes are missing, or they are from an
            %% older epoch.
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
    settle(Indexes, C#core{acks = Acks, heard = lists:usort([Peer | C#core.heard]), echoes = Echoes});
msg1({accept, _Epoch, _Indexes, _Stamp}, _Peer, C) ->
    {C, []};
msg1({catchup, From}, Peer, C = #core{commit = Commit, snap = Snap}) when From >= 1, From =< Snap ->
    %% The entries have been removed. The state that the entries produced
    %% is still held. The state as of the commit index serves as well as
    %% the state as of the snapshot.
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
    %% A leader cannot tell whether its own proposals below `Index' are the
    %% values that were decided at those indexes. By the argument at
    %% `learned' below, this leader has been deposed.
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
msg1({learned, Entries}, Peer, C0 = #core{log = Log0, role = Role, epoch = Mine, snap = Snap}) ->
    New = [{I, {learned, Value}} || {I, Value} <- Entries, I > Snap, not is_learned(I, Log0)],
    %% TLA+ Conflict. A leader should learn no value from this message that
    %% the leader did not propose itself, for two reasons:
    %%   - Every undecided index that the leader knows of holds a proposal
    %%     of the leader.
    %%   - A lower epoch cannot have decided an index beyond those indexes
    %%     without the phase-one quorum of the leader having reported it.
    %% Therefore a later epoch decided the index in both of these cases:
    %%   - The index is decided with a value that differs from the proposal
    %%     of the leader.
    %%   - The index is decided and the leader has not proposed at it.
    %% The commit index of the leader must not come to cover such an index
    %% while followers still read the commit index as "the leader's proposal
    %% was decided". The leader also must not go on to propose at such an
    %% index. The leader steps down.
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
    %% A full batch means that the peer probably holds more decided entries.
    %% This server asks for the next batch now and does not wait for the
    %% next heartbeat. The request is sent only if the batch contained an
    %% entry that this server did not hold, so that a repeated batch does
    %% not produce a repeated request.
    More = [{send, Peer, {catchup, C3#core.commit + 1}} || length(Entries) >= ?MAX_BATCH, New =/= []],
    {C3, [{persist, #{entries => New}} || New =/= []] ++ Follow ++ Applied ++ More}.

%% TLA+ FollowerCommit. Starting from the first uncommitted index, this
%% function marks as decided every entry that the commit index of the leader
%% covers and that is from the epoch of the leader. The function stops at
%% the first index whose entry is not decided and is not from the epoch of
%% the leader.
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

%% Returns this server to the follower role. Every caller that was waiting
%% on this server as leader is told that the outcome is unknown. A later
%% leader may still decide the value of such a caller.
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
            %% The value was decided more than once. It is applied once. The
            %% reply is the reply that was recorded the first time.
            resolve(I, Tag, Reply, C);
        #{ClientId := {Later, _Reply, _At}} when Later > Seq ->
            %% This is an old copy. It was decided after the client moved
            %% to a higher sequence number.
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
    %% The entry is now applied, so it is no longer a configuration entry
    %% above the commit index.
    resolve(I, Tag, ok, C#core{acfg = Cfg, cfgs = maps:remove(I, Cfgs)});
apply_value(I, {'$noop', Tag}, C) ->
    resolve(I, Tag, noop, C).

%% Eviction is by index. Every server agrees on the index, so every server
%% evicts the same client. A client that is evicted while it still has a
%% value in flight loses the at-most-once protection for that value.
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
            %% TLA+ MayIntroduce, `joint'. The caller that asked for the
            %% change is answered when the final entry is applied.
            {C1, Effects} = propose(undefined, silent, {cfg, {joint, Old, New}}, C),
            {C1#core{reconf = From}, Effects};
        {{final, _Old}, 0, ok} ->
            propose(From, value, {cfg, {final, New}}, C);
        {_, _, {error, Reason}} ->
            {C, [{reply, From, {error, {invalid_quorum, Reason}}}]};
        _ ->
            {C, [{reply, From, {error, reconfiguration_in_progress}}]}
    end.

%% The actions that a leader must take for the configuration. This function
%% runs after every event.
membership(C = #core{role = leader, id = Id, acfg = ACfg, cfgs = Cfgs}) when map_size(Cfgs) =:= 0 ->
    case ACfg of
        {joint, _Old, New} ->
            %% TLA+ MayIntroduce, `final'. The joint entry is decided and no
            %% configuration entry has followed it. Whichever server is the
            %% leader when this is the case proposes the final entry.
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
                %% This leader has completed its own removal. A server that
                %% is still a member becomes the leader after this. The
                %% members are first told that the change is decided. Until
                %% one of the members knows that the change is decided, the
                %% members cannot elect a leader without the servers that
                %% they replaced.
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

%% Replies to the caller that is waiting on index I, if there is one.
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
            %% The value of another leader was decided at this index. The
            %% proposal of this leader was tied to this index, so the
            %% proposal will never be decided.
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
