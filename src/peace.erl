%% @doc peace: replicated state machines over Flexible Paxos.
%%
%% The programming model follows ra. You implement `peace_machine', start a
%% cluster of servers that each run it, and submit values. peace agrees on
%% one order for the values and applies them, in that order, everywhere.
%%
%% ```
%% Ids = [{counter, N} || N <- ['a@host', 'b@host', 'c@host']],
%% {ok, _Started, []} = peace:start_cluster(Ids, {module, counter, []}, #{}),
%% {ok, 5, Leader} = peace:propose(Ids, {add, 5}),
%% {ok, 5, _} = peace:consistent_query(Leader, fun(Count) -> Count end).
%% '''
%%
%% Where it departs from ra is the quorum. Raft needs a majority for both
%% electing a leader and replicating an entry. Flexible Paxos lets the two
%% differ, as long as they intersect; see `peace_quorum'.
%%
%% ```
%% %% Five members. Two acknowledgements commit a value; four elect a leader.
%% peace:start_cluster(Ids, Machine, #{quorum => {counting, 4, 2}}).
%% '''
%%
%% == Against the thesis ==
%%
%% The protocol and its words are from Heidi Howard's thesis
%% (UCAM-CL-TR-935, in `docs/'): Multi-Paxos (section 3.6) under revision A's
%% quorums (4.1). `peace_core' says section by section what is from it and
%% what is not. The programming model, the names in this module among them,
%% is ra's, with one word changed: what ra calls a command is a value
%% here, as it is in the thesis.
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

%% A server is a locally registered name on a node, as in ra.
-type server_id() :: {Name :: atom(), node()}.
-type epoch() :: {Round :: non_neg_integer(), server_id() | none}.
-type index() :: pos_integer().
-type role() :: follower | candidate | leader.

%% What does not vary between the members of a cluster.
-type cluster_opts() :: #{
    quorum => peace_quorum:spec(),
    %% `{Module, Args}'. Default `{peace_storage_mem, #{}}', which is not
    %% durable; see `peace_storage_mem'.
    storage => peace_storage:storage(),
    %% A follower campaigns after hearing nothing for between T and 2T.
    %% Default 1000.
    election_timeout_ms => pos_integer(),
    %% Default a fifth of the election timeout.
    heartbeat_ms => pos_integer(),
    %% A server snapshots its machine state and drops its log every this many
    %% applied indexes. Default 4096; `infinity' for never.
    snapshot_interval => pos_integer() | infinity,
    %% How many clients' sessions are remembered. Must be the same on every
    %% member. Default 10000.
    max_sessions => pos_integer(),
    %% `quorum': a leader sends each proposal to a phase-two quorum of
    %% acceptors and no further, and the rest learn on the heartbeat
    %% (thesis section 4.3.3). Default `all'. See "Proposing to a phase-two
    %% quorum" in `peace_core'.
    propose_to => all | quorum,
    %% Lets a leader answer `consistent_query' from its own state. Must be
    %% the same on every member, at most the election timeout, and assumes
    %% clocks that run within ten per cent of each other. Off by default.
    %% See "Read leases" in `peace_core'.
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
    %% For tests that plant a bug, to show a check can fail. Read only in a
    %% test build (`TEST' defined); ignored in any other.
    unsafe_no_quorum_check => boolean(),
    unsafe_no_conflict_step_down => boolean(),
    unsafe_no_snapshot_guard => boolean(),
    unsafe_no_lease_fence => boolean(),
    unsafe_no_joint => boolean(),
    %% The rate of this server's clock, `{Num, Den}'. Test builds only.
    test_clock_rate => {pos_integer(), pos_integer()},
    %% Called with every step the server's core takes. Test builds only.
    test_tracer => fun((peace_server:step()) -> term())
}.

%% `session' makes the value safe to retry: see `propose/3'.
-type propose_opts() :: #{
    timeout => timeout(),
    session => {ClientId :: term(), Seq :: non_neg_integer()}
}.

-type propose_ret() ::
    {ok, Reply :: term(), Leader :: server_id()}
    | {error, term()}
    | {timeout, server_id()}.

%% How many times a request follows a "not the leader" answer before giving
%% up. Each hop is a full call timeout in the worst case.
-define(MAX_HOPS, 5).

%% ---------------------------------------------------------------------------
%% Starting and stopping
%% ---------------------------------------------------------------------------

%% @doc Starts one server on each member's node, and returns which started.
%%
%% The `peace' application must be running on every node. A cluster is usable
%% as soon as a phase-one quorum of it is up; the first election happens by
%% timeout, or straight away with `trigger_election/1'.
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

%% @doc Starts a server on this node, under the `peace' application. Also how
%% a stopped server is brought back: with a durable storage backend it
%% resumes where it left off.
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

%% @doc Proposes a value and waits for it to be decided and applied.
%%
%% The thesis's proposer is handed a candidate value and returns the value
%% decided (section 2.2). Here the value is handed to the leader, the
%% distinguished proposer of Multi-Paxos (section 3.6), which assigns it an
%% index and proposes it there, so what is decided at that index is this
%% value or, if the leader is deposed first, perhaps another.
%%
%% Given one server, the value goes there and follows redirects to the
%% leader. Given a list, each is tried in turn until one knows a leader.
%%
%% `{ok, Reply, Leader}' means the value was decided and applied, and
%% `Reply' is what the machine returned.
%%
%% `{timeout, Server}', `{error, leadership_lost}' and
%% `{error, {server_down, Reason}}' mean the outcome is unknown: the value
%% may be applied later, or never.
%%
%% `{error, no_leader}', `{error, noproc}' and `{error, too_many_redirects}'
%% mean the value was not submitted.
%%
%% The third argument is a timeout, or options. With
%% `session => {ClientId, Seq}' a value whose outcome is unknown can be
%% submitted again with the same session and will be applied at most once;
%% the retry is answered with the reply the first application got. A client
%% picks an id nobody else uses, has one value in flight at a time, and
%% gives each new value a higher `Seq' than the last. A copy of a value
%% the client has since moved on from is answered
%% `{error, {session_superseded, Seq}}' and not applied. Without a session,
%% a retried value may be applied twice.
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

%% @doc Proposes a value without waiting. Not a thesis term: the name is
%% `propose/2' with the usual suffix. Nothing is sent back, and nothing
%% says whether `Server' was the leader. For values whose effect is observed
%% some other way.
-spec propose_async(server_id(), peace_machine:value()) -> ok.
propose_async(Server, Value) ->
    gen_server:cast(Server, {value, Value}).

%% @equiv consistent_query(ServerOrServers, Fun, 5000)
-spec consistent_query(server_id() | [server_id()], fun((peace_machine:state()) -> Result)) ->
    {ok, Result, server_id()} | {error, term()} | {timeout, server_id()}.
consistent_query(ServerOrServers, Fun) ->
    consistent_query(ServerOrServers, Fun, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Runs `Fun' on the machine state at a point in the log that follows
%% every value acknowledged before the query was made: a linearizable read.
%% It is ordered by replicating a no-op, so it costs what a value costs,
%% unless the cluster has `read_lease_ms' set and the leader holds a lease,
%% in which case it is answered at once from the leader's state.
-spec consistent_query(server_id() | [server_id()], fun((peace_machine:state()) -> Result), timeout()) ->
    {ok, Result, server_id()} | {error, term()} | {timeout, server_id()}.
consistent_query(ServerOrServers, Fun, Timeout) when is_function(Fun, 1) ->
    leader_call(servers(ServerOrServers), {consistent_query, Fun}, Timeout, ?MAX_HOPS, no_leader).

%% @equiv local_query(Server, Fun, 5000)
-spec local_query(server_id(), fun((peace_machine:state()) -> Result)) ->
    {ok, Result, Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
local_query(Server, Fun) ->
    local_query(Server, Fun, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Runs `Fun' on whatever state `Server' has applied so far. Cheap, and
%% possibly stale: a follower lags its leader, and a deposed leader may not
%% know it yet.
-spec local_query(server_id(), fun((peace_machine:state()) -> Result), timeout()) ->
    {ok, Result, Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
local_query(Server, Fun, Timeout) when is_function(Fun, 1) ->
    call(Server, {local_query, Fun}, Timeout).

%% @equiv members(Server, 5000)
-spec members(server_id()) ->
    {ok, [server_id()], Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
members(Server) ->
    members(Server, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc The cluster's members and the leader, as `Server' believes them.
-spec members(server_id(), timeout()) ->
    {ok, [server_id()], Leader :: server_id() | undefined} | {error, term()} | {timeout, server_id()}.
members(Server, Timeout) ->
    call(Server, members, Timeout).

%% @equiv change_members(ServerOrServers, Members, Quorum, 5000)
-spec change_members(server_id() | [server_id()], [server_id()], peace_quorum:spec()) -> propose_ret().
change_members(ServerOrServers, Members, Quorum) ->
    change_members(ServerOrServers, Members, Quorum, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Changes who the members are, how they form quorums, or both.
%%
%% Any configuration to any other: adding, removing, replacing every member,
%% or keeping the members and changing the quorum system. The cluster passes
%% through a joint configuration, in which a value needs a phase-two quorum
%% of the old and of the new, so there is no moment at which the two could
%% decide separately. `{ok, ok, Leader}' means the new configuration alone
%% is in force.
%%
%% A server being added must be running first. Start it with `members' set
%% to the cluster as it is now, without the new server in it:
%% `start_server(#{id => New, members => Current, ...})'. It waits to be
%% told. A server that is removed stops taking part and may then be stopped.
%% If the leader is removed it sees the change through and stands down.
%%
%% The change survives a change of leader: `{error, leadership_lost}' and a
%% timeout mean it may yet complete, and `members/1' says whether it has.
%% One change at a time: `{error, reconfiguration_in_progress}'. A new
%% configuration needs a phase-two quorum of its own members reachable, or
%% nothing more is decided until they are.
-spec change_members(server_id() | [server_id()], [server_id()], peace_quorum:spec(), timeout()) ->
    propose_ret().
change_members(ServerOrServers, Members, Quorum, Timeout) when is_list(Members) ->
    leader_call(servers(ServerOrServers), {reconfigure, {Members, Quorum}}, Timeout, ?MAX_HOPS, no_leader).

%% @doc A snapshot of one server's view, for people and for tests.
-spec overview(server_id()) -> map() | {error, term()} | {timeout, server_id()}.
overview(Server) ->
    call(Server, overview, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Makes `Server' campaign now instead of waiting out its election
%% timeout.
-spec trigger_election(server_id()) -> ok.
trigger_election(Server) ->
    gen_server:cast(Server, trigger_election).

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

servers(Servers) when is_list(Servers) -> Servers;
servers(Server) -> [Server].

%% Tries each server in turn. A server that names a leader sends the request
%% there next; one that knows of none, or is not running, passes it on to the
%% next in the list. An answer whose outcome is unknown ends the attempt:
%% retrying it is the caller's decision, not this function's.
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
        %% The server or the connection to it went away with the request
        %% possibly delivered.
        exit:{Reason, _} -> {error, {server_down, Reason}}
    end.
