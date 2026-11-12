%% @doc One node of a key-value store, for the Jepsen test. See
%% jepsen/README.md.
%%
%% The node runs one peace server with the `peace_kv' machine, and an HTTP
%% server for the clients of the test. This module is not part of the peace
%% application. It is compiled only in the `jepsen' profile.
%%
%% Start a node with:
%%
%% ```
%% erl -sname peace@n1 -setcookie jepsen -pa ... \
%%     -peace data_dir '"/opt/peace/data"' \
%%     -peace_kv_node members peace@n1,peace@n2,peace@n3 \
%%     -peace_kv_node port 8080 \
%%     -s peace_kv_node
%% '''
%%
%% `members' lists the nodes of the cluster. The server of this node is
%% `{peace_kv, node()}'. A node that is started again recovers its state
%% from the default storage backend, the write-ahead log.
%%
%% The optional argument `-peace_kv_node read_lease_ms N' sets the
%% `read_lease_ms' option of the cluster.
%%
%% The optional argument `-peace_kv_node quorum Spec' sets the quorum system.
%% `Spec' is one of:
%%
%% <ul>
%% <li>`majority', the default.</li>
%% <li>`counting:Q1:Q2', for `{counting, Q1, Q2}'.</li>
%% <li>`grid:Row/Row/...', for `{grid, Rows}'. A row is a list of node names
%%   that are separated by `+'. Example:
%%   `grid:peace@n1+peace@n2/peace@n3+peace@n4'.</li>
%% <li>`weighted:Node=Weight+Node=Weight+...', for
%%   `{module, peace_kv_quorum, Weights}'. A node that is not listed has the
%%   weight 1. Example: `weighted:peace@n1=2+peace@n2=1'.</li>
%% </ul>
%%
%% The optional argument `-peace_kv_node clock_rate N/D' makes the clock of
%% the peace server run at `N/D' times the rate of the monotonic clock of
%% the node. It sets the `test_clock_rate' option, which exists only in a
%% build with the `TEST' macro. The Jepsen test uses this argument to test
%% the assumption of read leases about clock rates.
%%
%% The optional argument `-peace_kv_node reads stale' makes the node answer a
%% read from the state of its own server, with `peace:local_query/3'. The
%% answer can be stale. The Jepsen test uses this argument to confirm that
%% the checker rejects a history that is not linearizable. The default is
%% `consistent', which uses `peace:consistent_query/3'.
-module(peace_kv_node).

-export([start/0, server/0, members/1, quorum/1, reads/0]).

-define(NAME, peace_kv).

start() ->
    {ok, _} = application:ensure_all_started(peace),
    Members = members(arg(members)),
    Lease = [{read_lease_ms, list_to_integer(L)} || L <- args(read_lease_ms)],
    Rate = [{test_clock_rate, clock_rate(R)} || R <- args(clock_rate)],
    Config = maps:merge(
        #{
            id => server(),
            members => Members,
            machine => peace_kv:machine(),
            quorum => quorum(arg(quorum, "majority"))
        },
        maps:from_list(Lease ++ Rate)
    ),
    ok = peace:start_server(Config),
    {ok, _} = peace_kv_http:start(list_to_integer(arg(port, "8080"))),
    ok.

%% The peace server of this node.
server() ->
    {?NAME, node()}.

%% How the node answers a read: `consistent' or `stale'.
reads() ->
    case arg(reads, "consistent") of
        "consistent" -> consistent;
        "stale" -> stale
    end.

%% Converts a comma-separated list of node names to server ids.
members(Nodes) ->
    [{?NAME, list_to_atom(Node)} || Node <- string:lexemes(Nodes, ",")].

%% Converts the `quorum' argument to a quorum system.
quorum("majority") ->
    majority;
quorum("counting:" ++ Sizes) ->
    [Q1, Q2] = string:lexemes(Sizes, ":"),
    {counting, list_to_integer(Q1), list_to_integer(Q2)};
quorum("grid:" ++ Rows) ->
    {grid, [members(lists:join(",", string:lexemes(Row, "+"))) || Row <- string:lexemes(Rows, "/")]};
quorum("weighted:" ++ Weights) ->
    {module, peace_kv_quorum,
        maps:from_list([
            begin
                [Node, Weight] = string:lexemes(Pair, "="),
                {{?NAME, list_to_atom(Node)}, list_to_integer(Weight)}
            end
         || Pair <- string:lexemes(Weights, "+")
        ])}.

%% Converts `N/D' to a clock rate.
clock_rate(Rate) ->
    [Num, Den] = string:lexemes(Rate, "/"),
    {list_to_integer(Num), list_to_integer(Den)}.

arg(Key) ->
    case args(Key) of
        [Value] -> Value;
        [] -> error({missing_argument, Key})
    end.

arg(Key, Default) ->
    case args(Key) of
        [Value] -> Value;
        [] -> Default
    end.

%% The values of `-peace_kv_node Key Value' on the command line.
args(Key) ->
    case init:get_argument(?MODULE) of
        {ok, Lists} -> [Value || [K, Value] <- Lists, K =:= atom_to_list(Key)];
        error -> []
    end.
