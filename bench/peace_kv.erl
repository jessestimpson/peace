%% @doc A key-value state machine for benchmarks and tests.
%%
%% This module is a `peace_machine' and a client for that machine. It is not
%% part of the peace application. It is compiled only in the `bench'
%% profile.
%%
%% The machine state is a map from keys to values. The machine accepts four
%% values:
%%
%% <ul>
%% <li>`{put, Key, Value}' stores `Value' under `Key'. The reply is
%%   `ok'.</li>
%% <li>`{get, Key}' changes nothing. The reply is `{ok, Value}' or
%%   `not_found'.</li>
%% <li>`{delete, Key}' removes `Key'. The reply is `ok'.</li>
%% <li>`{cas, Key, Expected, New}' stores `New' under `Key' if the current
%%   value of `Key' equals `Expected'. The reply is `ok', or
%%   `{error, {mismatch, Current}}', or `{error, not_found}' if `Key' is
%%   absent.</li>
%% </ul>
%%
%% Every client function returns the reply of the machine and the leader
%% that answered: `{ok, Reply, Leader}'. A client function returns the
%% errors of `peace:propose/3' unchanged.
%%
%% A read has three forms, in order of decreasing cost:
%%
%% <ul>
%% <li>`get/3' proposes `{get, Key}'. The read is decided at an index of the
%%   log, as a write is.</li>
%% <li>`read/3' calls `peace:consistent_query/3'. The read is linearizable.
%%   The read is answered from the state of the leader if the cluster has
%%   `read_lease_ms' set and the leader holds a lease.</li>
%% <li>`stale_read/3' calls `peace:local_query/3'. The result may be
%%   stale.</li>
%% </ul>
-module(peace_kv).

-behaviour(peace_machine).

-export([machine/0]).
-export([put/4, get/3, delete/3, cas/5, read/3, stale_read/3]).
-export([init/1, apply/3]).

-export_type([key/0, val/0, opts/0]).

-type key() :: term().
-type val() :: term().
-type servers() :: peace:server_id() | [peace:server_id()].
%% The third argument of `peace:propose/3'.
-type opts() :: timeout() | peace:propose_opts().

%% ---------------------------------------------------------------------------
%% Client
%% ---------------------------------------------------------------------------

%% @doc The machine argument for `peace:start_cluster/3'.
-spec machine() -> peace_machine:machine().
machine() ->
    {module, ?MODULE, []}.

-spec put(servers(), key(), val(), opts()) -> {ok, ok, peace:server_id()} | {error, term()} | {timeout, peace:server_id()}.
put(Servers, Key, Value, Opts) ->
    peace:propose(Servers, {put, Key, Value}, Opts).

-spec get(servers(), key(), opts()) ->
    {ok, {ok, val()} | not_found, peace:server_id()} | {error, term()} | {timeout, peace:server_id()}.
get(Servers, Key, Opts) ->
    peace:propose(Servers, {get, Key}, Opts).

-spec delete(servers(), key(), opts()) -> {ok, ok, peace:server_id()} | {error, term()} | {timeout, peace:server_id()}.
delete(Servers, Key, Opts) ->
    peace:propose(Servers, {delete, Key}, Opts).

-spec cas(servers(), key(), val(), val(), opts()) ->
    {ok, ok | {error, not_found | {mismatch, val()}}, peace:server_id()}
    | {error, term()}
    | {timeout, peace:server_id()}.
cas(Servers, Key, Expected, New, Opts) ->
    peace:propose(Servers, {cas, Key, Expected, New}, Opts).

-spec read(servers(), key(), timeout()) ->
    {ok, {ok, val()} | not_found, peace:server_id()} | {error, term()} | {timeout, peace:server_id()}.
read(Servers, Key, Timeout) ->
    peace:consistent_query(Servers, fun(State) -> lookup(Key, State) end, Timeout).

-spec stale_read(peace:server_id(), key(), timeout()) ->
    {ok, {ok, val()} | not_found, peace:server_id() | undefined} | {error, term()} | {timeout, peace:server_id()}.
stale_read(Server, Key, Timeout) ->
    peace:local_query(Server, fun(State) -> lookup(Key, State) end, Timeout).

%% ---------------------------------------------------------------------------
%% peace_machine
%% ---------------------------------------------------------------------------

init(_Args) ->
    #{}.

apply(_Meta, {put, Key, Value}, State) ->
    {State#{Key => Value}, ok};
apply(_Meta, {get, Key}, State) ->
    {State, lookup(Key, State)};
apply(_Meta, {delete, Key}, State) ->
    {maps:remove(Key, State), ok};
apply(_Meta, {cas, Key, Expected, New}, State) ->
    case State of
        #{Key := Expected} -> {State#{Key := New}, ok};
        #{Key := Current} -> {State, {error, {mismatch, Current}}};
        _ -> {State, {error, not_found}}
    end.

lookup(Key, State) ->
    case State of
        #{Key := Value} -> {ok, Value};
        _ -> not_found
    end.
