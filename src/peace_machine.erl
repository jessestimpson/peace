%% @doc The behaviour a replicated state machine implements.
%%
%% The API is modelled on ra. You write a deterministic state machine. peace
%% agrees on the order of values. Every server applies each value in that
%% order.
%%
%% ```
%% -module(counter).
%% -behaviour(peace_machine).
%% -export([init/1, apply/3]).
%%
%% init(_Args) -> 0.
%%
%% apply(_Meta, {add, N}, Count) -> {Count + N, Count + N};
%% apply(_Meta, reset, Count) -> {0, Count}.
%% '''
%%
%% == Determinism ==
%%
%% `apply/3' runs on every server and must return the same result on each
%% server. The result must depend only on the arguments. `apply/3' must not
%% use:
%%
%% <ul>
%% <li>a clock,</li>
%% <li>`rand',</li>
%% <li>`node()',</li>
%% <li>the process dictionary, or</li>
%% <li>ETS.</li>
%% </ul>
%%
%% Put any input of that kind in the value. The client that submits the
%% value then chooses the input once.
%%
%% `apply/3' can run more than once for the same value on the same server. A
%% server that restarts rebuilds its state by applying its log again. For
%% that reason `apply/3' must not perform side effects. `apply/3' returns
%% the side effects as effects instead.
%%
%% == Effects ==
%%
%% Effects come from two callbacks, and the rule differs for each:
%%
%% <ul>
%% <li>The effects that `apply/3' returns are performed only by the leader.
%%   A server performs them only if it is the leader at the time it applies
%%   the value. A follower or a candidate discards them. They are never
%%   performed during recovery, because a server that starts applies its
%%   log as a follower.</li>
%% <li>The effects that `state_enter/2' returns are performed by the server
%%   whose role changed, whatever the new role is. They are also performed
%%   when a server starts, after recovery, with the role `follower'.</li>
%% </ul>
%%
%% The effects are:
%%
%% <ul>
%% <li>`{send_msg, Dest, Msg}' - sends `Msg' to `Dest'. `Dest' is a pid, a
%%   locally registered name, or `{Name, Node}' for a name registered on
%%   another node.</li>
%% <li>`{mod_call, Module, Function, Args}' - calls a function and ignores
%%   the result. The call runs in the server process, so the function must
%%   not block.</li>
%% </ul>
%%
%% An effect that `apply/3' returns is performed at most once per
%% leadership. It is not guaranteed to be performed at all. If a leader
%% crashes after it commits a value and before it performs the effects of
%% that value, those effects are lost. A new leader uses `state_enter/2' to
%% issue again every effect that the state shows to be outstanding.
-module(peace_machine).

-export([init/1, apply/4, state_enter/3]).

-export_type([machine/0, state/0, value/0, reply/0, meta/0, effect/0, effects/0]).

-type machine() :: {module, module(), Args :: term()}.
-type state() :: term().
-type value() :: term().
-type reply() :: term().
%% `index' is the position of the value in the replicated log.
-type meta() :: #{index := peace:index()}.
-type effect() ::
    {send_msg, Dest :: pid() | atom() | {atom(), node()}, Msg :: term()}
    | {mod_call, module(), atom(), [term()]}.
-type effects() :: [effect()].

-callback init(Args :: term()) -> state().

-callback apply(meta(), value(), state()) ->
    {state(), reply()} | {state(), reply(), effects()}.

%% Called on the server whose role changed, with the new role and the
%% current state of that server. Also called once when a server starts,
%% with the role `follower'. That server performs the returned effects,
%% whatever the role is. This differs from the effects of `apply/3', which
%% only the leader performs.
-callback state_enter(peace:role(), state()) -> effects().

-optional_callbacks([state_enter/2]).

%% @private
-spec init(machine()) -> state().
init({module, Mod, Args}) ->
    Mod:init(Args).

%% @private
-spec apply(machine(), meta(), value(), state()) -> {state(), reply(), effects()}.
apply({module, Mod, _Args}, Meta, Value, State) ->
    case Mod:apply(Meta, Value, State) of
        {State1, Reply} -> {State1, Reply, []};
        {State1, Reply, Effects} when is_list(Effects) -> {State1, Reply, Effects}
    end.

%% @private
-spec state_enter(machine(), peace:role(), state()) -> effects().
state_enter({module, Mod, _Args}, Role, State) ->
    case erlang:function_exported(Mod, state_enter, 2) of
        true -> Mod:state_enter(Role, State);
        false -> []
    end.
