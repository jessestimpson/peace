%% The machine the simulation replicates: it remembers every value with the
%% index it was applied at, and answers each with that index. Enough for the
%% harness to compare what a client was told against what was decided.
-module(peace_dst_machine).

-behaviour(peace_machine).

-export([init/1, apply/3]).

init(_Args) ->
    [].

apply(#{index := I}, Value, History) ->
    {[{I, Value} | History], I}.
