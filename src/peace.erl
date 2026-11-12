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
    start_server/1,
    stop_server/1,
    propose/2,
    propose/3,
    propose_async/2,
    consistent_query/2,
    consistent_query/3,
    local_query/2,
    local_query/3,
    members/1,
    members/2,
    change_members/3,
    change_members/4,
    overview/1,
    trigger_election/1
]).

-export_type([
    server_id/0,
    epoch/0,
    index/0,
    role/0,
    server_config/0,
    propose_opts/0,
    cluster_opts/0
]).

%% A server is identified by a locally registered name and a node, as in ra.
-type server_id() :: {Name :: atom(), node()}.
-type epoch() :: {Round :: non_neg_integer(), server_id() | none}.
-type index() :: pos_integer().
-type role() :: follower | candidate | leader.

%% The options that are the same for every member of a cluster.
-type cluster_opts() :: #{
    quorum => peace_quorum:spec(),
    %% `{Module, Args}'. The default is `{peace_storage_mem, #{}}'. The
    %% default backend is not durable. See `peace_storage_mem'.
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
    %% The number of client sessions that are remembered. The value must be
    %% the same on every member. The default is 10000.
    max_sessions => pos_integer(),
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

-type server_config() :: #{
    id := server_id(),
    members := [server_id()],
    machine := peace_machine:machine(),
    quorum => peace_quorum:spec(),
    storage => peace_storage:storage(),
    election_timeout_ms => pos_integer(),
    heartbeat_ms => pos_integer(),
    snapshot_interval => pos_integer() | infinity,
    max_sessions => pos_integer(),
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
    session => {ClientId :: term(), Seq :: non_neg_integer()}
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

%% @doc Starts one server on each member's node. Returns the servers that
%% started and the servers that did not start.
%%
%% The `peace' application must be running on every node. A cluster is usable
%% as soon as a phase-one quorum of its members is running. The first
%% election happens when an election timeout expires, or immediately if
%% `trigger_election/1' is called.
-spec start_cluster([server_id()], peace_machine:machine(), cluster_opts()) ->
    {ok, Started :: [server_id()], NotStarted :: [server_id()]} | {error, term()}.
start_cluster(ServerIds, Machine, Opts) ->
    case peace_quorum:validate(maps:get(quorum, Opts, majority), ServerIds) of
        ok ->
            Results = [
                {Id, start_on(Node, Opts#{id => Id, members => ServerIds, machine => Machine})}
             || Id = {_Name, Node} <- ServerIds
            ],
            Started = [Id || {Id, ok} <- Results],
            NotStarted = [Id || {Id, Result} <- Results, Result =/= ok],
            case Started of
                [] -> {error, cluster_not_formed};
                _ -> {ok, Started, NotStarted}
            end;
        {error, Reason} ->
            {error, {invalid_quorum, Reason}}
    end.

start_on(Node, Config) when Node =:= node() ->
    start_server(Config);
start_on(Node, Config) ->
    try
        erpc:call(Node, ?MODULE, start_server, [Config])
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% @doc Starts a server on this node, under the `peace' application. This
%% function also restarts a stopped server. With a durable storage backend,
%% the restarted server resumes from its stored state.
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
%% <li>`{error, no_leader}', `{error, noproc}' and
%%   `{error, too_many_redirects}': the value was not submitted.</li>
%% </ul>
%%
%% The third argument is either a timeout or a map of options.
%%
%% With the option `session => {ClientId, Seq}', a value whose outcome is
%% unknown can be submitted again with the same session. The value is then
%% applied at most once. The retry is answered with the reply that the first
%% application produced.
%%
%% A client that uses sessions must:
%%
%% <ul>
%% <li>choose a `ClientId' that no other client uses,</li>
%% <li>have one value in flight at a time, and</li>
%% <li>give each new value a higher `Seq' than the previous value.</li>
%% </ul>
%%
%% A copy of an older value, submitted after the client has moved to a higher
%% `Seq', is not applied. The copy is answered
%% `{error, {session_superseded, Seq}}'. Without a session, a retried value
%% may be applied twice.
-spec propose(server_id() | [server_id()], peace_machine:value(), timeout() | propose_opts()) ->
    propose_ret().
propose(ServerOrServers, Value, Opts) when is_map(Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_CALL_TIMEOUT_MS),
    Request =
        case Opts of
            #{session := Session = {_ClientId, Seq}} when is_integer(Seq), Seq >= 0 ->
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
%% other way.
-spec propose_async(server_id(), peace_machine:value()) -> ok.
propose_async(Server, Value) ->
    gen_server:cast(Server, {value, Value}).

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
    call(Server, {local_query, Fun}, Timeout).

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
    call(Server, members, Timeout).

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
%% new server with `members' set to the current members of the cluster,
%% without the new server:
%% `start_server(#{id => New, members => Current, ...})'. The new server
%% then waits until it is told about the change. A server that is removed
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
    leader_call(servers(ServerOrServers), {reconfigure, {Members, Quorum}}, Timeout, ?MAX_HOPS, no_leader).

%% @doc Returns a map that describes the current view of one server. The map
%% is intended for people and for tests.
-spec overview(server_id()) -> map() | {error, term()} | {timeout, server_id()}.
overview(Server) ->
    call(Server, overview, ?DEFAULT_CALL_TIMEOUT_MS).

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
    case call(Server, Request, Timeout) of
        {error, {not_leader, undefined}} ->
            leader_call(Rest, Request, Timeout, Hops, no_leader);
        {error, {not_leader, Leader}} ->
            leader_call([Leader | Rest -- [Leader]], Request, Timeout, Hops - 1, no_leader);
        {error, noproc} ->
            leader_call(Rest, Request, Timeout, Hops, noproc);
        Other ->
            Other
    end.

call(Server, Request, Timeout) ->
    try
        gen_server:call(Server, Request, Timeout)
    catch
        exit:{timeout, _} -> {timeout, Server};
        exit:{noproc, _} -> {error, noproc};
        %% The server stopped, or the connection to the server was lost. The
        %% request may have been delivered.
        exit:{Reason, _} -> {error, {server_down, Reason}}
    end.
