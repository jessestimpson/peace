%% @doc peace: replicated state machines over Flexible Paxos.
%%
%% The programming model follows ra. You implement `peace_machine', start a
%% cluster of servers that each run it, and submit commands. peace agrees on
%% one order for the commands and applies them, in that order, everywhere.
%%
%% ```
%% Ids = [{counter, N} || N <- ['a@host', 'b@host', 'c@host']],
%% {ok, _Started, []} = peace:start_cluster(Ids, {module, counter, []}, #{}),
%% {ok, 5, Leader} = peace:process_command(Ids, {add, 5}),
%% {ok, 5, _} = peace:consistent_query(Leader, fun(Count) -> Count end).
%% '''
%%
%% Where it departs from ra is the quorum. Raft needs a majority for both
%% electing a leader and replicating an entry. Flexible Paxos lets the two
%% differ, as long as they intersect; see `peace_quorum'.
%%
%% ```
%% %% Five members. Two acknowledgements commit a command; four elect a leader.
%% peace:start_cluster(Ids, Machine, #{quorum => {counting, 4, 2}}).
%% '''
%%
%% == Not here yet ==
%%
%% Membership change, snapshots and log truncation, leader leases, and
%% pre-vote. The log grows without bound, a `consistent_query/2' costs a round
%% of replication, and a member that was partitioned away disrupts the leader
%% once when it returns.
-module(peace).

-include("peace.hrl").
-include("peace_eta.hrl").

-export([
    start_cluster/3,
    start_server/1,
    stop_server/1,
    process_command/2,
    process_command/3,
    pipeline_command/2,
    consistent_query/2,
    consistent_query/3,
    local_query/2,
    local_query/3,
    members/1,
    members/2,
    overview/1,
    trigger_election/1
]).

-export_type([
    server_id/0,
    ballot/0,
    index/0,
    role/0,
    server_config/0,
    cluster_opts/0
]).

%% A server is a locally registered name on a node, as in ra.
-type server_id() :: {Name :: atom(), node()}.
-type ballot() :: {Round :: non_neg_integer(), server_id() | none}.
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
    heartbeat_ms => pos_integer()
}.

-type server_config() :: #{
    id := server_id(),
    members := [server_id()],
    machine := peace_machine:machine(),
    quorum => peace_quorum:spec(),
    storage => peace_storage:storage(),
    election_timeout_ms => pos_integer(),
    heartbeat_ms => pos_integer(),
    %% For tests that plant a bug, to show a check can fail. Never set these.
    unsafe_no_quorum_check => boolean(),
    unsafe_no_conflict_step_down => boolean()
}.

-type command_ret() ::
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
%% as soon as a phase-1 quorum of it is up; the first election happens by
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
%% Commands and queries
%% ---------------------------------------------------------------------------

%% @equiv process_command(ServerOrServers, Command, 5000)
-spec process_command(server_id() | [server_id()], peace_machine:command()) -> command_ret().
process_command(ServerOrServers, Command) ->
    process_command(ServerOrServers, Command, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Submits a command and waits for it to be applied.
%%
%% Given one server, the command goes there and follows redirects to the
%% leader. Given a list, each is tried in turn until one knows a leader.
%%
%% `{ok, Reply, Leader}' means the command was chosen and applied, and
%% `Reply' is what the machine returned.
%%
%% `{timeout, Server}', `{error, leadership_lost}' and
%% `{error, {server_down, Reason}}' mean the outcome is unknown: the command may be applied later, or never. peace does not
%% deduplicate, so a command that is retried after either must be safe to
%% apply twice, or carry an id the machine can recognise.
%%
%% `{error, no_leader}', `{error, noproc}' and `{error, too_many_redirects}'
%% mean the command was not submitted.
-spec process_command(server_id() | [server_id()], peace_machine:command(), timeout()) ->
    command_ret().
process_command(ServerOrServers, Command, Timeout) ->
    leader_call(servers(ServerOrServers), {command, Command}, Timeout, ?MAX_HOPS, no_leader).

%% @doc Submits a command without waiting. Nothing is sent back, and nothing
%% says whether `Server' was the leader. For commands whose effect is observed
%% some other way.
-spec pipeline_command(server_id(), peace_machine:command()) -> ok.
pipeline_command(Server, Command) ->
    gen_server:cast(Server, {command, Command}).

%% @equiv consistent_query(ServerOrServers, Fun, 5000)
-spec consistent_query(server_id() | [server_id()], fun((peace_machine:state()) -> Result)) ->
    {ok, Result, server_id()} | {error, term()} | {timeout, server_id()}.
consistent_query(ServerOrServers, Fun) ->
    consistent_query(ServerOrServers, Fun, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Runs `Fun' on the machine state at a point in the log that follows
%% every command acknowledged before the query was made: a linearizable read.
%% It is ordered by replicating a no-op, so it costs what a command costs.
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
