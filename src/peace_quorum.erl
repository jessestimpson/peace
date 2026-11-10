%% @doc Quorum systems for Flexible Paxos.
%%
%% Paxos asks any two quorums to intersect. Howard's thesis (UCAM-CL-TR-935,
%% in `docs/', chapter 4, "Quorum intersection revised") shows that the safety
%% proof uses only one intersection: between the quorum that promised to a
%% new leader (phase one) and the quorums earlier leaders got acceptances from
%% (phase two). Her revision A (section 4.1, equation 4.4), published as
%% Flexible Paxos, keeps exactly that: every phase-one quorum intersects every
%% phase-two quorum.
%%
%% Two phase-two quorums may be disjoint, and so may two phase-one quorums. A
%% cluster can therefore trade one phase against the other. Multi-Paxos runs
%% phase two for every command and phase one only when the leader changes
%% (section 4.3.3), so small phase-two quorums make the steady state faster and
%% more tolerant of slow members, and the price is paid at elections.
%%
%% The built-in systems:
%%
%% <ul>
%% <li>`majority' - classic Paxos. More than half, for both phases.</li>
%% <li>`{counting, Q1, Q2}' - any `Q1' members for phase one and any `Q2' for
%%   phase two, with `Q1 + Q2 > N'. Some points on that line have names in the
%%   thesis (sections 4.3.2 and 4.3.3):
%%   <ul>
%%   <li>`{counting, N div 2 + 1, N div 2}' for even `N' - the even nodes
%%     optimisation. One fewer acknowledgement per command than a majority,
%%     at no cost anywhere else.</li>
%%   <li>`{counting, N, 1}' - Singleton Paxos. The leader commits alone;
%%     electing one needs everybody.</li>
%%   <li>`{counting, 1, N}' - All aboard Paxos. Anybody leads without asking;
%%     committing needs everybody.</li>
%%   </ul></li>
%% <li>`{grid, Rows}' - members arranged in rows. Phase two needs every member
%%   of one row; phase one needs one member from every row. Replication
%%   survives the loss of every row but one. The thesis's running example
%%   (section 4.1.3) is a two-by-two grid of this kind.</li>
%% <li>`{module, Mod, Arg}' - your own, implementing this behaviour.</li>
%% </ul>
%%
%% The quorum system is fixed for the life of a cluster. The thesis goes on
%% to let it vary by epoch (revision B, section 4.2) and to let a proposer
%% stop collecting promises early depending on what they say (revision C,
%% chapter 5). peace implements neither.
%%
%% {@link validate/2} is what stands between a cluster and a quorum system
%% that loses data, and `peace_server' refuses to start without it passing.
%% For up to 16 members it does not trust the arithmetic: it enumerates every
%% subset and looks for a phase-one quorum whose complement is a phase-two quorum,
%% which is precisely a pair that does not intersect. That covers custom
%% modules too.
-module(peace_quorum).

-export([
    is_phase_one_quorum/3,
    is_phase_two_quorum/3,
    validate/2
]).

-export_type([spec/0]).

-type spec() ::
    majority
    | {counting, Q1 :: pos_integer(), Q2 :: pos_integer()}
    | {grid, Rows :: [[peace:server_id()]]}
    | {module, module(), Arg :: term()}.

%% Custom quorum systems. Both must be monotone: a superset of a quorum is a
%% quorum. `Set' is always a duplicate-free subset of `Members'.
-callback is_phase_one_quorum(Arg :: term(), Members :: [peace:server_id()], Set :: [peace:server_id()]) ->
    boolean().
-callback is_phase_two_quorum(Arg :: term(), Members :: [peace:server_id()], Set :: [peace:server_id()]) ->
    boolean().

%% Above this many members, exhaustive validation costs more than it is worth
%% and the built-in systems are checked by their own arithmetic instead.
-define(EXHAUSTIVE_MAX, 16).

%% @doc Whether `Set' is enough promises to lead.
-spec is_phase_one_quorum(spec(), [peace:server_id()], [peace:server_id()]) -> boolean().
is_phase_one_quorum(majority, Members, Set) ->
    2 * count(Members, Set) > length(Members);
is_phase_one_quorum({counting, Q1, _Q2}, Members, Set) ->
    count(Members, Set) >= Q1;
is_phase_one_quorum({grid, Rows}, _Members, Set) ->
    lists:all(fun(Row) -> lists:any(fun(M) -> lists:member(M, Set) end, Row) end, Rows);
is_phase_one_quorum({module, Mod, Arg}, Members, Set) ->
    Mod:is_phase_one_quorum(Arg, Members, members_of(Members, Set)).

%% @doc Whether `Set' is enough acceptances for a value to be decided.
-spec is_phase_two_quorum(spec(), [peace:server_id()], [peace:server_id()]) -> boolean().
is_phase_two_quorum(majority, Members, Set) ->
    2 * count(Members, Set) > length(Members);
is_phase_two_quorum({counting, _Q1, Q2}, Members, Set) ->
    count(Members, Set) >= Q2;
is_phase_two_quorum({grid, Rows}, _Members, Set) ->
    lists:any(fun(Row) -> lists:all(fun(M) -> lists:member(M, Set) end, Row) end, Rows);
is_phase_two_quorum({module, Mod, Arg}, Members, Set) ->
    Mod:is_phase_two_quorum(Arg, Members, members_of(Members, Set)).

%% @doc Checks that a quorum system is well formed, safe, and able to make
%% progress when every member is up.
-spec validate(spec(), [peace:server_id()]) -> ok | {error, term()}.
validate(Spec, Members) ->
    case Members =/= [] andalso length(lists:usort(Members)) =:= length(Members) of
        false ->
            {error, {invalid_members, Members}};
        true ->
            case shape(Spec, Members) of
                ok -> intersects(Spec, Members);
                Error -> Error
            end
    end.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

shape(majority, _Members) ->
    ok;
shape({counting, Q1, Q2}, Members) when is_integer(Q1), is_integer(Q2) ->
    N = length(Members),
    case Q1 >= 1 andalso Q2 >= 1 andalso Q1 =< N andalso Q2 =< N of
        true -> ok;
        false -> {error, {quorum_size_out_of_range, {counting, Q1, Q2}, N}}
    end;
shape({grid, Rows}, Members) when is_list(Rows) ->
    Flat = lists:append(Rows),
    case
        Rows =/= [] andalso
            lists:all(fun(R) -> R =/= [] end, Rows) andalso
            lists:sort(Flat) =:= lists:sort(Members)
    of
        true -> ok;
        false -> {error, {grid_rows_must_partition_members, Rows}}
    end;
shape({module, Mod, _Arg}, _Members) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} ->
            case
                erlang:function_exported(Mod, is_phase_one_quorum, 3) andalso
                    erlang:function_exported(Mod, is_phase_two_quorum, 3)
            of
                true -> ok;
                false -> {error, {not_a_quorum_module, Mod}}
            end;
        _ ->
            {error, {not_a_quorum_module, Mod}}
    end;
shape(Spec, _Members) ->
    {error, {unknown_quorum_spec, Spec}}.

intersects(Spec, Members) ->
    case
        is_phase_one_quorum(Spec, Members, Members) andalso
            is_phase_two_quorum(Spec, Members, Members)
    of
        false ->
            {error, {quorum_unreachable, Spec}};
        true when length(Members) =< ?EXHAUSTIVE_MAX ->
            exhaustive(Spec, Members);
        true ->
            arithmetic(Spec, Members)
    end.

%% For monotone quorum systems, some phase-one quorum misses some phase-two quorum
%% exactly when there is a set that is a phase-one quorum while its complement
%% is a phase-two quorum. 2^N checks rather than 4^N.
exhaustive(Spec, Members) ->
    N = length(Members),
    exhaustive(Spec, Members, 0, 1 bsl N).

exhaustive(_Spec, _Members, Mask, Mask) ->
    ok;
exhaustive(Spec, Members, Mask, End) ->
    {In, Out} = split(Members, Mask, [], []),
    case is_phase_one_quorum(Spec, Members, In) andalso is_phase_two_quorum(Spec, Members, Out) of
        true -> {error, {quorums_do_not_intersect, #{phase_one => In, phase_two => Out}}};
        false -> exhaustive(Spec, Members, Mask + 1, End)
    end.

split([], _Mask, In, Out) ->
    {lists:reverse(In), lists:reverse(Out)};
split([M | Rest], Mask, In, Out) when Mask band 1 =:= 1 ->
    split(Rest, Mask bsr 1, [M | In], Out);
split([M | Rest], Mask, In, Out) ->
    split(Rest, Mask bsr 1, In, [M | Out]).

arithmetic(majority, _Members) ->
    ok;
arithmetic({counting, Q1, Q2}, Members) ->
    case Q1 + Q2 > length(Members) of
        true -> ok;
        false -> {error, {quorums_do_not_intersect, {counting, Q1, Q2}}}
    end;
arithmetic({grid, _Rows}, _Members) ->
    %% One from every row always meets any whole row.
    ok;
arithmetic({module, _Mod, _Arg}, _Members) ->
    %% Too large to enumerate. The module is taken at its word.
    ok.

count(Members, Set) ->
    length(members_of(Members, Set)).

members_of(Members, Set) ->
    [M || M <- lists:usort(Set), lists:member(M, Members)].
