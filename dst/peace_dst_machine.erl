%% This module is the machine that the simulation replicates. The machine
%% stores every value together with the index at which the value was
%% applied. The machine replies to each value with that index. This is
%% enough for the harness to compare the reply that a client received with
%% the values that were decided.
-module(peace_dst_machine).

-behaviour(peace_machine).

-export([init/1, apply/3]).

init(_Args) ->
    [].

apply(#{index := I}, Value, History) ->
    {[{I, Value} | History], I}.
