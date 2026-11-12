%% @doc A custom quorum system for the Jepsen test: weighted voting.
%%
%% `Arg' is a map from a server id to the weight of that server. A server
%% that is not in the map has the weight 1. A set of members is a phase-one
%% quorum and a phase-two quorum if the set holds more than half of the
%% total weight of the members. Two such sets always intersect.
%%
%% The Jepsen test uses this module to test the `{module, Mod, Arg}' quorum
%% system of `peace_quorum'. This module is not part of the peace
%% application. It is compiled only in the `jepsen' profile.
-module(peace_kv_quorum).

-behaviour(peace_quorum).

-export([is_phase_one_quorum/3, is_phase_two_quorum/3]).

is_phase_one_quorum(Weights, Members, Set) ->
    is_quorum(Weights, Members, Set).

is_phase_two_quorum(Weights, Members, Set) ->
    is_quorum(Weights, Members, Set).

is_quorum(Weights, Members, Set) ->
    2 * weight(Weights, Set) > weight(Weights, Members).

weight(Weights, Ids) ->
    lists:sum([maps:get(Id, Weights, 1) || Id <- Ids]).
