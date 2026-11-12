%% A machine for tests. The machine state is a key-value map and a history.
%% The history records the order in which values were applied, so that two
%% replicas can be compared exactly.
-module(peace_test_machine).

-behaviour(peace_machine).

-export([init/1, apply/3, state_enter/2]).

init(Args) ->
    #{kv => #{}, history => [], notify => maps:get(notify, Args, undefined)}.

apply(#{index := I}, {put, K, V}, S = #{kv := KV, history := H}) ->
    {S#{kv := KV#{K => V}, history := [{I, {put, K, V}} | H]}, ok};
apply(#{index := I}, {get, K}, S = #{kv := KV, history := H}) ->
    {S#{history := [{I, {get, K}} | H]}, maps:get(K, KV, undefined)};
apply(#{index := I}, {tell, Pid, Msg}, S = #{history := H}) ->
    {S#{history := [{I, {tell, Msg}} | H]}, ok, [{send_msg, Pid, {told, Msg}}]}.

state_enter(Role, #{notify := Pid}) when is_pid(Pid) ->
    [{send_msg, Pid, {state_enter, Role}}];
state_enter(_Role, _State) ->
    [].
