%% @doc peace: replicated state machines over Flexible Paxos.
%%
%% The API is modelled on ra. To use peace:
%%
%% <ol>
%% <li>Implement the `peace_machine' behaviour.</li>
%% <li>Start a cluster of servers. Each server runs the machine.</li>
%% <li>Submit values to the cluster.</li>
%% </ol>
%%
%% peace agrees on one order for the values. Every server applies the values
%% in that order.
%%
%% ```
%% Ids = [{counter, N} || N <- ['a@host', 'b@host', 'c@host']],
%% {ok, _Started, []} = peace:start_cluster(Ids, {module, counter, []}, #{}),
%% {ok, 5, Leader} = peace:propose(Ids, {add, 5}),
%% {ok, 5, _} = peace:consistent_query(Leader, fun(Count) -> Count end).
%% '''
%%
%% peace differs from ra in the quorum system. Raft requires a majority to
%% elect a leader and a majority to replicate an entry. Flexible Paxos allows
%% the quorum that elects a leader and the quorum that replicates an entry to
%% differ. The two kinds of quorum must intersect. See `peace_quorum'.
%%
%% ```
%% %% The cluster has five members. Two acknowledgements commit a value.
%% %% Four acknowledgements elect a leader.
%% peace:start_cluster(Ids, Machine, #{quorum => {counting, 4, 2}}).
%% '''
%%
%% == Relation to the thesis ==
%%
%% The protocol and the protocol terms come from Heidi Howard's thesis
%% (UCAM-CL-TR-935, in `docs/'). The protocol is Multi-Paxos (section 3.6)
%% with the quorums of revision A (section 4.1). `peace_core' states, section
%% by section, which parts come from the thesis and which parts do not.
%%
%% The API, including the names in this module, is modelled on ra. One term
%% differs from ra. The item that a client submits is called a command in
%% ra. The same item is called a value in peace, as it is in the thesis.
-module(peace).

-include("peace.hrl").
-include("peace_eta.hrl").

-export([
    start_cluster/3,
    form_cluster/2,
    form_cluster/3,
    replace_member/2,
    replace_member/3,
    activate/1,
    activate/2,
    start_server/1,
    stop_server/1,
    propose/2,
    propose/3,
    propose_async/2,
    open_session/1,
    open_session/2,
    close_session/1,
    call/2,
    call/3,
    cast/2,
    consistent_query/2,
    consistent_query/3,
    local_query/2,
    local_query/3,
    members/1,
    members/2,
    change_members/3,
    change_members/4,
    overview/1,
    versions/0,
    trigger_election/1
]).

-export_type([
    server_id/0,
    member/0,
    epoch/0,
    index/0,
    role/0,
    server_config/0,
    propose_opts/0,
    cluster_opts/0
]).

%% A server is addressed by a locally registered name and a node, as in ra.
%% Every function of this module takes and returns addresses.
-type server_id() :: {Name :: atom(), node()}.

%% A member of a cluster is identified by its address and its incarnation.
%% A server creates its incarnation when it starts and recovers no stored
%% state. A server that has lost its stored state is therefore another
%% member than it was. See "Member identity" in `peace_server' and
%% `replace_member/3'.
-type member() :: {Name :: atom(), node(), Incarnation :: term()}.
-type epoch() :: {Round :: non_neg_integer(), member() | none}.
-type index() :: pos_integer().
-type role() :: follower | candidate | leader.

%% The options that are the same for every member of a cluster.
-type cluster_opts() :: #{
    quorum => peace_quorum:spec(),
    %% `{Module, Args}'. The default is `{peace_storage_wal, #{dir => Dir}}',
    %% where `Dir' is the application environment variable `data_dir' of
    %% `peace'. `data_dir' defaults to `"peace_data"', relative to the
    %% working directory. See `peace_storage_wal'.
    storage => peace_storage:storage(),
    %% T, in milliseconds. A follower that has received nothing from a
    %% leader for a time between T and 2T runs a pre-vote. The follower
    %% campaigns if a phase-one quorum answers the pre-vote. The default
    %% is 1000.
    election_timeout_ms => pos_integer(),
    %% The default is one fifth of the election timeout.
    heartbeat_ms => pos_integer(),
    %% Each time a server has applied this many indexes, the server takes a
    %% snapshot of its machine state and deletes its log. The default is
    %% 4096. `infinity' means that the server never takes a snapshot.
    snapshot_interval => pos_integer() | infinity,
    %% A server takes a snapshot when its commit index passes an index `I'
    %% with `I rem snapshot_interval =:= snapshot_offset'. The default is a
    %% hash of the server id, so that the servers of a cluster take their
    %% snapshots at different indexes.
    snapshot_offset => non_neg_integer(),
    %% A server sends a snapshot to another server in chunks of at most this
    %% many bytes. The default is 262144. See `peace_transfer'.
    snapshot_chunk_bytes => pos_integer(),
    %% The number of client sessions that are remembered. The value must be
    %% the same on every member. The default is 10000.
    max_sessions => pos_integer(),
    %% The number of replies that are remembered for each client session.
    %% A session can have this many values undecided at one time. The
    %% default is 64. See "Sessions" in `peace_core'.
    session_window => pos_integer(),
    %% The number of values that a leader holds undecided at one time. A
    %% leader that holds this many answers a further value or consistent
    %% query with `{error, overloaded}' and does not propose it. The default
    %% is 8192. `infinity' means that there is no limit.
    max_pending => pos_integer() | infinity,
    %% The number of client requests that a server holds unhandled, in its
    %% mailbox. A server that holds more refuses the newest requests. A
    %% leader answers `{error, overloaded}'. The default is 16384.
    %% `infinity' means that there is no limit. See "The mailbox limit" in
    %% `peace_server'.
    max_mailbox => pos_integer() | infinity,
    %% With `quorum', a leader sends each proposal only to a phase-two quorum
    %% of acceptors. The other acceptors learn the value on the heartbeat
    %% (thesis section 4.3.3). The default is `all'. See "Proposing to a
    %% phase-two quorum" in `peace_core'.
    propose_to => all | quorum,
    %% Allows a leader to answer `consistent_query' from the leader's own
    %% state.
    %%   - The value must be the same on every member.
    %%   - The value must be at most the election timeout.
    %%   - The option assumes that the members' clocks run within ten per
    %%     cent of each other.
    %% The option is off by default. See "Read leases" in `peace_core'.
    read_lease_ms => pos_integer()
}.

%% A server does not take the members of its cluster from this map. See
%% `form_cluster/3'.
-type server_config() :: #{
    id := server_id(),
    %% `peace_server' sets this key from the stored incarnation.
    member => member(),
    machine := peace_machine:machine(),
    storage => peace_storage:storage(),
    %% The addresses of servers of a cluster. A server that starts without
    %% stored state asks these servers to replace the member that has its
    %% address. Without this key the server waits for `replace_member/3'.
    %% See `replace_member/3'.
    rejoin => [server_id()],
    %% A passive server takes no part in the protocol until `activate/2' is
    %% called. See `activate/2'.
    passive => boolean(),
    %% A function that returns whether the gate of the server is open. While
    %% the gate is closed, the server behaves as a passive server. The
    %% server calls the function before it handles an event and before it
    %% sends a message of the protocol. The function must not block. See
    %% "The gate" in `peace_server'.
    gate => {module(), atom(), [term()]},
    election_timeout_ms => pos_integer(),
    heartbeat_ms => pos_integer(),
    snapshot_interval => pos_integer() | infinity,
    max_sessions => pos_integer(),
    session_window => pos_integer(),
    max_pending => pos_integer() | infinity,
    max_mailbox => pos_integer() | infinity,
    read_lease_ms => pos_integer(),
    propose_to => all | quorum,
    %% The `unsafe_' keys are for tests that plant a bug, to show that a
    %% check can fail. The keys are read only in a test build (`TEST'
    %% defined). Every other build ignores them.
    unsafe_no_quorum_check => boolean(),
    unsafe_no_conflict_step_down => boolean(),
    unsafe_no_snapshot_guard => boolean(),
    unsafe_no_lease_fence => boolean(),
    unsafe_no_joint => boolean(),
    unsafe_no_session_order => boolean(),
    unsafe_no_challenge => boolean(),
    unsafe_no_base_index => boolean(),
    unsafe_fixed_incarnation => boolean(),
    unsafe_send_latest => boolean(),
    unsafe_no_config_request => boolean(),
    %% The range of message versions of this server. This key is read only
    %% in a test build. See `peace_wire'.
    test_msg_versions => peace_wire:range(),
    %% The rate of this server's clock, as `{Num, Den}'. This key is read
    %% only in a test build.
    test_clock_rate => {pos_integer(), pos_integer()},
    %% A function that the server calls with every step of `peace_core'.
    %% This key is read only in a test build.
    test_tracer => fun((peace_server:step()) -> term())
}.

%% The `session' option makes the value safe to retry. See `propose/3'.
-type propose_opts() :: #{
    timeout => timeout(),
    session => {ClientId :: term(), Seq :: pos_integer()}
}.

-type propose_ret() ::
    {ok, Reply :: term(), Leader :: server_id()}
    | {error, term()}
    | {timeout, server_id()}.

%% The maximum number of times that a request follows a "not the leader"
%% answer. After that many hops the request fails. In the worst case, each
%% hop takes a full call timeout.
-define(MAX_HOPS, 5).

%% ---------------------------------------------------------------------------
%% Starting and stopping
%% ---------------------------------------------------------------------------

%% @doc Starts one server on each node and forms a cluster of the servers.
%%
%% The `peace' application must be running on every node. Every server must
%% start, because the configuration of the cluster names the incarnation of
%% every member. The first election happens when an election timeout
%% expires, or immediately if `trigger_election/1' is called.
%%
%% The function can be called again with the same arguments after it has
%% failed. A server that is already running is not started again.
-spec start_cluster([server_id()], peace_machine:machine(), cluster_opts()) ->
    {ok, Formed :: [server_id()], NotFormed :: [server_id()]} | {error, term()}.
start_cluster(ServerIds, Machine, Opts) ->
    Quorum = maps:get(quorum, Opts, majority),
    case peace_quorum:validate(Quorum, ServerIds) of
        ok ->
            Config = maps:remove(quorum, Opts),
            Results = [{Id, start_on(Node, Config#{id => Id, machine => Machine})} || Id = {_Name, Node} <- ServerIds],
            case [Id || {Id, Result} <- Results, Result =/= ok, Result =/= {error, already_started}] of
                [] -> form_cluster(ServerIds, Quorum);
                NotStarted -> {error, {not_started, NotStarted}}
            end;
        {error, Reason} ->
            {error, {invalid_quorum, Reason}}
    end.

%% @equiv form_cluster(ServerIds, Quorum, 5000)
-spec form_cluster([server_id()], peace_quorum:spec()) ->
    {ok, Formed :: [server_id()], NotFormed :: [server_id()]} | {error, term()}.
form_cluster(ServerIds, Quorum) ->
    form_cluster(ServerIds, Quorum, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Forms a cluster of servers that are running and that have no
%% configuration. `start_cluster/3' calls this function.
%%
%% The function:
%%
%% <ol>
%% <li>asks every server for its incarnation,</li>
%% <li>builds the configuration from the incarnations and `Quorum', and</li>
%% <li>stores the configuration on every server.</li>
%% </ol>
%%
%% Formation is separate from `start_server/1' for this reason. A server
%% that restarts with the same arguments and without its stored state must
%% not become the member that it was, because that member made promises
%% that the restarted server does not have. A server therefore takes its
%% first configuration only from this function, and stores it.
%%
%% A quorum system that names members, such as `{grid, Rows}', is given
%% with addresses. A custom quorum module receives the members as
%% `member()' terms.
%%
%% The function fails, and stores nothing, if a server does not answer or
%% if a server already has another configuration. The function can be
%% called again after it has stored the configuration on only some of the
%% servers. The servers on which the configuration is stored can decide
%% values if they contain the quorums.
%%
%% `Opts' can be a timeout, or a map with these keys:
%%
%% <ul>
%% <li>`timeout' - the timeout of each call to a server. The default is
%%   5000 ms.</li>
%% <li>`machine_state' - the machine state of the new cluster. Without this
%%   key, the machine state is the result of `init/1' of the machine. An
%%   example of its use is a cluster that continues from the machine state
%%   of an earlier cluster, which the caller read with `local_query/2'. See
%%   "Formation with a machine state" in `peace_core'. Every call that forms
%%   the same cluster must give the same state.</li>
%% <li>`members' - the members of the new cluster, with their incarnations.
%%   The function then does not ask the servers for their incarnations, and
%%   `ServerIds' can be a part of the cluster. A server stores the
%%   configuration only if the configuration names the incarnation of that
%%   server. The caller uses this key when it knows the incarnation of
%%   every member, for example because a storage backend supplies the
%%   incarnations. `Quorum' must name members and not addresses.</li>
%% </ul>
-spec form_cluster(
    [server_id()],
    peace_quorum:spec(),
    timeout() | #{timeout => timeout(), machine_state => peace_machine:state(), members => [member()]}
) ->
    {ok, Formed :: [server_id()], NotFormed :: [server_id()]} | {error, term()}.
form_cluster(ServerIds, Quorum, Opts) when is_map(Opts) ->
    Form =
        case Opts of
            #{machine_state := MState} -> fun(New) -> {form, New, {machine_state, MState}} end;
            #{} -> fun(New) -> {form, New} end
        end,
    Timeout = maps:get(timeout, Opts, ?DEFAULT_CALL_TIMEOUT_MS),
    case Opts of
        #{members := Members} ->
            case peace_quorum:validate(Quorum, Members) of
                ok -> store_configuration(ServerIds, Form({lists:usort(Members), Quorum}), Timeout);
                {error, Reason} -> {error, {invalid_quorum, Reason}}
            end;
        #{} ->
            form_cluster(ServerIds, Quorum, Timeout, Form)
    end;
form_cluster(ServerIds, Quorum, Timeout) ->
    form_cluster(ServerIds, Quorum, Timeout, fun(New) -> {form, New} end).

form_cluster(ServerIds, Quorum, Timeout, Form) ->
    Answers = [{Id, server_call(Id, identity, Timeout)} || Id <- ServerIds],
    case [Id || {Id, Answer} <- Answers, element(1, Answer) =/= ok] of
        [] ->
            Map = maps:from_list([{Id, Member} || {Id, {ok, Member, _Config}} <- Answers]),
            Members = lists:usort(maps:values(Map)),
            New = {Members, to_members(Quorum, Map)},
            Other = [
                Id
             || {Id, {ok, _Member, Config}} <- Answers, Config =/= none, Config =/= {final, New}
            ],
            case {Other, peace_quorum:validate(element(2, New), Members)} of
                {[], ok} ->
                    store_configuration(ServerIds, Form(New), Timeout);
                {[], {error, Reason}} ->
                    {error, {invalid_quorum, Reason}};
                _ ->
                    {error, {already_formed, Other}}
            end;
        NotRunning ->
            {error, {not_running, NotRunning}}
    end.

store_configuration(ServerIds, Request, Timeout) ->
    Results = [{Id, server_call(Id, Request, Timeout)} || Id <- ServerIds],
    case [Id || {Id, ok} <- Results] of
        [] -> {error, {cluster_not_formed, Results}};
        Formed -> {ok, Formed, ServerIds -- Formed}
    end.

%% Replaces the addresses that a quorum system names with members.
to_members({grid, Rows}, Map) when is_list(Rows) ->
    {grid, [[maps:get(Id, Map, Id) || Id <- Row] || Row <- Rows, is_list(Row)]};
to_members(Quorum, _Map) ->
    Quorum.

%% @equiv replace_member(ServerOrServers, New, 5000)
-spec replace_member(server_id() | [server_id()], server_id()) -> propose_ret().
replace_member(ServerOrServers, New) ->
    replace_member(ServerOrServers, New, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Replaces the member at the address `New' with the server that now
%% runs at that address.
%%
%% A server that starts without stored state has a new incarnation and no
%% configuration. The cluster still names the earlier incarnation, which no
%% longer exists. This function asks the leader to put the running server
%% in the place of that member. The running server keeps the position of
%% the member in the quorum system, for example its row in a grid. The
%% leader makes the change through a joint configuration, as
%% `change_members/4' does, and the running server then receives the
%% decided values from the leader.
%%
%% `ServerOrServers' are servers of the cluster. `New' must be running.
%%
%% A server that is started with `rejoin' asks for the replacement itself.
%% The leader then sends a challenge to the incarnation that asked, and
%% replaces the member only after that incarnation answers. The challenge
%% prevents a delayed request of an incarnation that no longer exists from
%% replacing a member that runs.
%%
%% Use `rejoin' only where a server without stored state is certain to have
%% lost its state. A disk that is not mounted when the node starts looks
%% like lost state. Several servers with that fault would each replace
%% their member and leave the data on their disks unused. For that reason a
%% server does not ask by default.
%%
%% The old configuration must still have a phase-one quorum and a
%% phase-two quorum without the member that is replaced.
-spec replace_member(server_id() | [server_id()], server_id(), timeout()) -> propose_ret().
replace_member(ServerOrServers, New, Timeout) ->
    case server_call(New, identity, Timeout) of
        {ok, Member, _Config} ->
            leader_call(servers(ServerOrServers), {replace, [Member]}, Timeout, ?MAX_HOPS, no_leader);
        Other ->
            Other
    end.

%% @doc Returns the range of versions of the messages between servers and
%% the format of stored data, for this version of peace. `message' is the
%% latest message version and `message_min' is the earliest. See "Versions"
%% in `peace_server'.
-spec versions() -> #{message := pos_integer(), message_min := pos_integer(), stored := pos_integer()}.
versions() ->
    #{message => ?MSG_VERSION, message_min => ?MSG_VERSION_MIN, stored => ?STORED_FORMAT}.

%% @equiv activate(Server, 5000)
-spec activate(server_id()) -> ok | {error, term()} | {timeout, server_id()}.
activate(Server) ->
    activate(Server, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Makes a passive server take part in the protocol.
%%
%% A server that is started with `passive => true' receives decided values
%% and sends no message of the protocol: it does not promise, does not
%% accept a proposal and does not campaign. The other servers cannot
%% distinguish it from a member that is not reachable. See "A passive
%% server" in `peace_core'.
%%
%% An application starts a server as passive when it has work to do between
%% the decision that admits the server and the first message of the server.
%% `overview/1' of the leader shows the configuration in force, and
%% `overview/1' of the passive server shows `passive => true'.
%%
%% The activation is stored. A server that restarts with its stored state
%% after the activation is not passive. The function returns `ok' for a
%% server that is not passive.
-spec activate(server_id(), timeout()) -> ok | {error, term()} | {timeout, server_id()}.
activate(Server, Timeout) ->
    server_call(Server, activate, Timeout).

start_on(Node, Config) when Node =:= node() ->
    start_server(Config);
start_on(Node, Config) ->
    try
        erpc:call(Node, ?MODULE, start_server, [Config])
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% @doc Starts a server on this node, under the `peace' application. This
%% function also restarts a stopped server.
%%
%% <ul>
%% <li>A server that recovers stored state resumes from that state, as the
%%   member that it was.</li>
%% <li>A server that recovers no stored state creates a new incarnation and
%%   has no configuration. Such a server becomes a member through
%%   `form_cluster/3', `change_members/4' or `replace_member/3'.</li>
%% </ul>
-spec start_server(server_config()) -> ok | {error, term()}.
start_server(Config = #{id := {_Name, Node}}) when Node =:= node() ->
    case peace_sup:start_server(Config) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> {error, already_started};
        {error, Reason} -> {error, Reason}
    end.

-spec stop_server(server_id()) -> ok | {error, term()}.
stop_server({Name, Node}) when Node =:= node() ->
    case whereis(Name) of
        undefined -> {error, not_started};
        Pid -> peace_sup:stop_server(Pid)
    end;
stop_server(Id = {_Name, Node}) ->
    try
        erpc:call(Node, ?MODULE, stop_server, [Id])
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% ---------------------------------------------------------------------------
%% Values and queries
%% ---------------------------------------------------------------------------

%% @equiv propose(ServerOrServers, Value, 5000)
-spec propose(server_id() | [server_id()], peace_machine:value()) -> propose_ret().
propose(ServerOrServers, Value) ->
    propose(ServerOrServers, Value, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Proposes a value and waits for the value to be decided and applied.
%%
%% In the thesis, a proposer is given a candidate value and returns the
%% decided value (section 2.2). In peace, the value is given to the leader.
%% The leader is the distinguished proposer of Multi-Paxos (section 3.6).
%% The leader assigns the value an index and proposes the value at that
%% index. The value decided at that index is this value, unless the leader
%% is deposed first. In that case a different value may be decided at that
%% index.
%%
%% If `ServerOrServers' is one server, the value is sent to that server and
%% the request follows redirects to the leader. If `ServerOrServers' is a
%% list, the servers are tried in order until one server knows a leader.
%%
%% The return values are:
%%
%% <ul>
%% <li>`{ok, Reply, Leader}': the value was decided and applied. `Reply' is
%%   the term that the machine returned.</li>
%% <li>`{timeout, Server}', `{error, leadership_lost}' and
%%   `{error, {server_down, Reason}}': the outcome is unknown. The value may
%%   be applied later, or never.</li>
%% <li>`{error, no_leader}', `{error, noproc}',
%%   `{error, too_many_redirects}' and `{error, overloaded}': the value was
%%   not submitted. `overloaded' means that the leader holds `max_pending'
%%   undecided values, or more than `max_mailbox' client requests. The
%%   caller can submit the value again later. A caller that submits the
%%   value again must first wait for a random time. Callers that submit
%%   again at once, or after the same fixed time, keep the leader
%%   overloaded.</li>
%% </ul>
%%
%% The third argument is either a timeout or a map of options.
%%
%% With the option `session => {ClientId, Seq}', a value whose outcome is
%% unknown can be submitted again with the same session. The value is then
%% applied at most once. The retry is answered with the reply that the first
%% application produced.
%%
%% A client that uses the `session' option must:
%%
%% <ul>
%% <li>choose a `ClientId' that no other client uses or has used,</li>
%% <li>give its first value the `Seq' 1, and</li>
%% <li>give each new value the `Seq' of the previous value plus 1.</li>
%% </ul>
%%
%% The values of one client are applied in the order of `Seq'. A client may
%% submit a value before the previous value has a reply. Three replies are
%% specific to sessions:
%%
%% <ul>
%% <li>`{error, {session_gap, Last}}': the value was not applied, because
%%   the value with the previous `Seq' is not applied. `Last' is the highest
%%   `Seq' that is applied. The client submits the values from `Last + 1'
%%   again, in order.</li>
%% <li>`{error, {session_superseded, Last}}': the value is a copy of a value
%%   that was applied. The cluster no longer holds the reply. The cluster
%%   holds the last `session_window' replies of a client.</li>
%% <li>`{error, {session_gap, 0}}' for a client that has received a reply:
%%   the cluster evicted the session. See `max_sessions'.</li>
%% </ul>
%%
%% `open_session/2' starts a process that follows these rules. Without a
%% session, a retried value may be applied twice.
-spec propose(server_id() | [server_id()], peace_machine:value(), timeout() | propose_opts()) ->
    propose_ret().
propose(ServerOrServers, Value, Opts) when is_map(Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_CALL_TIMEOUT_MS),
    Request =
        case Opts of
            #{session := Session = {_ClientId, Seq}} when is_integer(Seq), Seq >= 1 ->
                {value, Value, Session};
            #{session := Bad} ->
                error({badarg, {session, Bad}});
            _ ->
                {value, Value}
        end,
    leader_call(servers(ServerOrServers), Request, Timeout, ?MAX_HOPS, no_leader);
propose(ServerOrServers, Value, Timeout) ->
    leader_call(servers(ServerOrServers), {value, Value}, Timeout, ?MAX_HOPS, no_leader).

%% @doc Proposes a value without waiting for the result. `propose_async' is
%% not a thesis term. The name is `propose/2' with the usual suffix. The
%% caller receives no reply. The caller is not told whether `Server' was the
%% leader. Use this function for values whose effect is observed in some
%% other way. A leader that holds `max_pending' undecided values drops the
%% value.
-spec propose_async(server_id(), peace_machine:value()) -> ok.
propose_async(Server, Value) ->
    gen_server:cast(Server, {value, Value}).

%% @equiv open_session(ServerOrServers, #{})
-spec open_session(server_id() | [server_id()]) -> {ok, pid()} | {error, term()}.
open_session(ServerOrServers) ->
    open_session(ServerOrServers, #{}).

%% @doc Starts a session process and links it to the caller. Sessions are
%% not in the thesis.
%%
%% A session process submits values with `call/3' and `cast/2'. The values
%% of one session process are applied in the order in which the session
%% process received them, each at most once. The session process:
%%
%% <ul>
%% <li>has up to `window' values undecided at one time (the default is 64,
%%   and the value must be at most the `session_window' of the cluster),</li>
%% <li>finds the leader, and</li>
%% <li>submits a value again until the value has a reply.</li>
%% </ul>
%%
%% Several processes can use one session process. See `peace_session' for
%% the options and the limitations.
-spec open_session(server_id() | [server_id()], peace_session:opts()) -> {ok, pid()} | {error, term()}.
open_session(ServerOrServers, Opts) ->
    peace_session:start_link(servers(ServerOrServers), Opts).

%% @doc Stops a session process. Every value of the session that has no
%% reply is answered `{error, session_closed}'. The outcome of such a value
%% is unknown.
-spec close_session(pid()) -> ok.
close_session(Session) ->
    peace_session:stop(Session).

%% @equiv call(Session, Value, 5000)
-spec call(pid(), peace_machine:value()) -> peace_session:result() | {timeout, pid()}.
call(Session, Value) ->
    call(Session, Value, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Submits a value through a session process and waits for the reply.
%% `call' and `cast' are not thesis terms. The names are the `gen_server'
%% names for the same two forms of request.
%%
%% The return values are:
%%
%% <ul>
%% <li>`{ok, Reply}': the value was decided and applied once. `Reply' is the
%%   term that the machine returned.</li>
%% <li>`{timeout, Session}': the outcome is unknown. The value stays in the
%%   session. The session process continues to submit the value, and later
%%   values of the session wait for it.</li>
%% <li>`{error, session_evicted}' and `{error, session_closed}': the outcome
%%   is unknown.</li>
%% <li>`{error, {session_superseded, Seq}}': the value was applied once. The
%%   cluster no longer holds the reply.</li>
%% </ul>
%%
%% While `window' values have no reply, the call waits.
-spec call(pid(), peace_machine:value(), timeout()) -> peace_session:result() | {timeout, pid()}.
call(Session, Value, Timeout) ->
    peace_session:call(Session, Value, Timeout).

%% @doc Submits a value through a session process without waiting for the
%% reply. The calling process later receives `{peace_reply, Ref, Result}'.
%% `Ref' is the return value of this function. `Result' is one of the
%% return values of `call/3', except the timeout.
%%
%% While `window' values have no reply, this function waits. The function
%% returns when the session process has given the value its place in the
%% order.
-spec cast(pid(), peace_machine:value()) -> reference().
cast(Session, Value) ->
    peace_session:cast(Session, Value).

%% @equiv consistent_query(ServerOrServers, Fun, 5000)
-spec consistent_query(server_id() | [server_id()], fun((peace_machine:state()) -> Result)) ->
    {ok, Result, server_id()} | {error, term()} | {timeout, server_id()}.
consistent_query(ServerOrServers, Fun) ->
    consistent_query(ServerOrServers, Fun, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Runs `Fun' on the machine state at a point in the log that follows
%% every value acknowledged before the query was made. This is a
%% linearizable read. The query is ordered by replicating a no-op, so the
%% query costs the same as a value. There is one exception. If the cluster
%% has `read_lease_ms' set and the leader holds a lease, the query is
%% answered immediately from the leader's state.
-spec consistent_query(server_id() | [server_id()], fun((peace_machine:state()) -> Result), timeout()) ->
    {ok, Result, server_id()} | {error, term()} | {timeout, server_id()}.
consistent_query(ServerOrServers, Fun, Timeout) when is_function(Fun, 1) ->
    leader_call(servers(ServerOrServers), {consistent_query, Fun}, Timeout, ?MAX_HOPS, no_leader).

%% @equiv local_query(Server, Fun, 5000)
-spec local_query(server_id(), fun((peace_machine:state()) -> Result)) ->
    {ok, Result, Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
local_query(Server, Fun) ->
    local_query(Server, Fun, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Runs `Fun' on the state that `Server' has applied so far. The query
%% is cheap, and the result may be stale. A follower lags behind its leader.
%% A deposed leader may not yet know that it has been deposed.
-spec local_query(server_id(), fun((peace_machine:state()) -> Result), timeout()) ->
    {ok, Result, Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
local_query(Server, Fun, Timeout) when is_function(Fun, 1) ->
    server_call(Server, {local_query, Fun}, Timeout).

%% @equiv members(Server, 5000)
-spec members(server_id()) ->
    {ok, [server_id()], Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
members(Server) ->
    members(Server, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Returns the cluster's members and the leader, according to the
%% current state of `Server'.
-spec members(server_id(), timeout()) ->
    {ok, [server_id()], Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
members(Server, Timeout) ->
    server_call(Server, members, Timeout).

%% @equiv change_members(ServerOrServers, Members, Quorum, 5000)
-spec change_members(server_id() | [server_id()], [server_id()], peace_quorum:spec()) -> propose_ret().
change_members(ServerOrServers, Members, Quorum) ->
    change_members(ServerOrServers, Members, Quorum, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Changes the members, the quorum system, or both.
%%
%% Any configuration can be changed to any other configuration. A change
%% can:
%%
%% <ul>
%% <li>add members,</li>
%% <li>remove members,</li>
%% <li>replace every member, or</li>
%% <li>keep the members and change the quorum system.</li>
%% </ul>
%%
%% During the change, the cluster uses a joint configuration. In the joint
%% configuration, a value needs a phase-two quorum of the old configuration
%% and a phase-two quorum of the new configuration. Therefore there is no
%% moment at which the old configuration and the new configuration could
%% decide separately. `{ok, ok, Leader}' means that only the new
%% configuration is in force.
%%
%% A server that is being added must be running before the change. Start the
%% new server with `start_server/1'. The new server has no configuration
%% and waits until it is told about the change. This function asks each
%% server in `Members' that answers for its incarnation. An address whose
%% server does not answer stands for the member that has that address. A
%% server that is removed
%% stops taking part and may then be stopped. If the leader is removed, the
%% leader completes the change and then steps down.
%%
%% The change survives a change of leader. `{error, leadership_lost}' and a
%% timeout mean that the change may still complete. Call `members/1' to find
%% out whether the change has completed.
%%
%% Only one change can be in progress at a time. A request made during
%% another change is answered `{error, reconfiguration_in_progress}'.
%%
%% A phase-two quorum of the new configuration's own members must be
%% reachable. Until such a quorum is reachable, no further value is decided.
-spec change_members(server_id() | [server_id()], [server_id()], peace_quorum:spec(), timeout()) ->
    propose_ret().
change_members(ServerOrServers, Members, Quorum, Timeout) when is_list(Members) ->
    Map = maps:from_list([
        {Id, Member}
     || Id <- Members, {ok, Member, _Config} <- [server_call(Id, identity, Timeout)]
    ]),
    New = {[maps:get(Id, Map, Id) || Id <- Members], to_members(Quorum, Map)},
    leader_call(servers(ServerOrServers), {reconfigure, New}, Timeout, ?MAX_HOPS, no_leader).

%% @doc Returns a map that describes the current view of one server. The map
%% is intended for people and for tests.
%%
%% `message_versions' holds the range of message versions of the server
%% under `own', and under `peers' the range of each server from which the
%% server has received a message, by address. See `peace_wire'.
-spec overview(server_id()) -> map() | {error, term()} | {timeout, server_id()}.
overview(Server) ->
    server_call(Server, overview, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Makes `Server' campaign immediately, without waiting for its
%% election timeout to expire.
-spec trigger_election(server_id()) -> ok.
trigger_election(Server) ->
    gen_server:cast(Server, trigger_election).

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

servers(Servers) when is_list(Servers) -> Servers;
servers(Server) -> [Server].

%% Tries each server in order.
%%   - If a server names a leader, the request is sent to that leader next.
%%   - If a server knows no leader, or is not running, the request is sent
%%     to the next server in the list.
%%   - If the outcome of an answer is unknown, this function stops and
%%     returns the answer. The caller decides whether to retry.
leader_call([], _Request, _Timeout, _Hops, LastError) ->
    {error, LastError};
leader_call(_Servers, _Request, _Timeout, 0, _LastError) ->
    {error, too_many_redirects};
leader_call([Server | Rest], Request, Timeout, Hops, _LastError) ->
    case server_call(Server, Request, Timeout) of
        {error, {not_leader, undefined}} ->
            leader_call(Rest, Request, Timeout, Hops, no_leader);
        {error, {not_leader, Leader}} ->
            leader_call([Leader | Rest -- [Leader]], Request, Timeout, Hops - 1, no_leader);
        {error, noproc} ->
            leader_call(Rest, Request, Timeout, Hops, noproc);
        Other ->
            Other
    end.

server_call(Server, Request, Timeout) ->
    try
        gen_server:call(Server, Request, Timeout)
    catch
        exit:{timeout, _} -> {timeout, Server};
        exit:{noproc, _} -> {error, noproc};
        %% The server stopped, or the connection to the server was lost. The
        %% request may have been delivered.
        exit:{Reason, _} -> {error, {server_down, Reason}}
    end.
