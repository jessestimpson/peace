%% @doc Supervises every peace server on this node.
%%
%% The servers are `transient':
%%
%% <ul>
%% <li>A server that crashes is restarted. The restarted server recovers its
%%   promise and its log from its storage backend.</li>
%% <li>A server that is stopped with `peace:stop_server/1' stays
%%   stopped.</li>
%% </ul>
-module(peace_sup).

-behaviour(supervisor).

-export([start_link/0, start_server/1, stop_server/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_server(peace:server_config()) -> {ok, pid()} | {error, term()}.
start_server(Config) ->
    supervisor:start_child(?MODULE, [Config]).

-spec stop_server(pid()) -> ok | {error, term()}.
stop_server(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 5, period => 10},
    Child = #{
        id => peace_server,
        start => {peace_server, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker
    },
    {ok, {SupFlags, [Child]}}.
