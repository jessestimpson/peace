%% @doc Quorum systems for Flexible Paxos.
%%
%% Paxos requires any two quorums to intersect. Howard's thesis
%% (UCAM-CL-TR-935, in `docs/', chapter 4, "Quorum intersection revised")
%% shows that the safety proof uses only one intersection. That intersection
%% is between:
%%
%% <ul>
%% <li>the quorum that promised to a new leader (phase one), and</li>
%% <li>the quorums from which earlier leaders received acceptances (phase
%%   two).</li>
%% </ul>
%%
%% Revision A of the thesis (section 4.1, equation 4.4) was published as
%% Flexible Paxos. Revision A keeps exactly that requirement: every phase-one
%% quorum intersects every phase-two quorum.
%%
%% Two phase-two quorums may be disjoint. Two phase-one quorums may also be
%% disjoint. A cluster can therefore make the quorums of one phase smaller by
%% making the quorums of the other phase larger. Multi-Paxos runs phase two
%% for every value and runs phase one only when the leader changes (section
%% 4.3.3). Small phase-two quorums therefore make normal operation faster and
%% more tolerant of slow members. The cost of small phase-two quorums falls
%% on elections.
%%
%% The built-in quorum systems are:
%%
%% <ul>
%% <li>`majority' - classic Paxos. Both phases need more than half of the
%%   members.</li>
%% <li>`{counting, Q1, Q2}' - phase one needs any `Q1' members and phase two
%%   needs any `Q2' members, with `Q1 + Q2 > N'. The thesis names some of
%%   these combinations (sections 4.3.2 and 4.3.3):
%%   <ul>
%%   <li>`{counting, N div 2 + 1, N div 2}' for even `N' - the even nodes
%%     optimisation. Each value needs one fewer acknowledgement than with a
%%     majority. Nothing else costs more.</li>
%%   <li>`{counting, N, 1}' - Singleton Paxos. The leader commits a value
%%     alone. Electing a leader needs every member.</li>
%%   <li>`{counting, 1, N}' - All aboard Paxos. Any member can become leader
%%     without a promise from another member. Committing a value needs every
%%     member.</li>
%%   </ul></li>
%% <li>`{grid, Rows}' - the members are arranged in rows. Phase two needs
%%   every member of one row. Phase one needs one member from every row.
%%   Replication continues after the loss of every row but one. The running
%%   example in the thesis (section 4.1.3) is a two-by-two grid of this
%%   kind.</li>
%% <li>`{module, Mod, Arg}' - a custom quorum system. `Mod' implements this
%%   behaviour.</li>
%% </ul>
%%
%% The quorum system is chosen when a cluster starts. A running cluster
%% changes its quorum system only through `peace:change_members/3,4'. That
%% function replaces the members and the quorum system by a configuration
%% change that is decided in the log. See "Membership" in `peace_core'. The
%% quorum system does not vary by epoch. The thesis describes two further
%% revisions:
%%
%% <ul>
%% <li>Revision B (section 4.2) lets the quorum system vary by epoch.</li>
%% <li>Revision C (chapter 5) lets a proposer stop collecting promises early,
%%   depending on the content of the promises.</li>
%% </ul>
%%
%% peace implements neither revision B nor revision C. Membership change
%% in peace is related to revision B but does not implement it. See
%% "Membership" in `peace_core'.
%%
%% {@link validate/2} rejects a quorum system that loses data. `peace_server'
%% refuses to start unless `validate/2' passes. For up to 16 members,
%% `validate/2' does not rely on arithmetic. It enumerates every subset of
%% the members and looks for a phase-one quorum whose complement is a
%% phase-two quorum. Such a pair is exactly a phase-one quorum and a
%% phase-two quorum that do not intersect. The enumeration covers custom
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

%% The callbacks for a custom quorum system. Both callbacks must be monotone:
%% a superset of a quorum is a quorum. `Set' is always a duplicate-free
%% subset of `Members'.
-callback is_phase_one_quorum(Arg :: term(), Members :: [peace:server_id()], Set :: [peace:server_id()]) ->
    boolean().
-callback is_phase_two_quorum(Arg :: term(), Members :: [peace:server_id()], Set :: [peace:server_id()]) ->
    boolean().

%% Above this many members, exhaustive validation is too expensive. The
%% built-in quorum systems are then checked by arithmetic instead.
-define(EXHAUSTIVE_MAX, 16).

%% @doc Returns whether promises from the members of `Set' are enough to
%% become leader.
-spec is_phase_one_quorum(spec(), [peace:server_id()], [peace:server_id()]) -> boolean().
is_phase_one_quorum(majority, Members, Set) ->
    2 * count(Members, Set) > length(Members);
is_phase_one_quorum({counting, Q1, _Q2}, Members, Set) ->
    count(Members, Set) >= Q1;
is_phase_one_quorum({grid, Rows}, _Members, Set) ->
    lists:all(fun(Row) -> lists:any(fun(M) -> lists:member(M, Set) end, Row) end, Rows);
is_phase_one_quorum({module, Mod, Arg}, Members, Set) ->
    Mod:is_phase_one_quorum(Arg, Members, members_of(Members, Set)).

%% @doc Returns whether acceptances from the members of `Set' are enough for
%% a value to be decided.
-spec is_phase_two_quorum(spec(), [peace:server_id()], [peace:server_id()]) -> boolean().
is_phase_two_quorum(majority, Members, Set) ->
    2 * count(Members, Set) > length(Members);
is_phase_two_quorum({counting, _Q1, Q2}, Members, Set) ->
    count(Members, Set) >= Q2;
is_phase_two_quorum({grid, Rows}, _Members, Set) ->
    lists:any(fun(Row) -> lists:all(fun(M) -> lists:member(M, Set) end, Row) end, Rows);
is_phase_two_quorum({module, Mod, Arg}, Members, Set) ->
    Mod:is_phase_two_quorum(Arg, Members, members_of(Members, Set)).

%% @doc Checks that a quorum system is well formed, is safe, and can make
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

%% For a monotone quorum system, these two statements are equivalent:
%%   - Some phase-one quorum does not intersect some phase-two quorum.
%%   - Some set is a phase-one quorum and the complement of that set is a
%%     phase-two quorum.
%% This function checks the second statement. The second statement needs
%% 2^N checks. The first statement would need 4^N checks.
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
    %% A set with one member from every row always intersects any whole row.
    ok;
arithmetic({module, _Mod, _Arg}, _Members) ->
    %% The cluster is too large to enumerate. The custom module is assumed
    %% to be correct and is not checked.
    ok.

count(Members, Set) ->
    length(members_of(Members, Set)).

members_of(Members, Set) ->
    [M || M <- lists:usort(Set), lists:member(M, Members)].
