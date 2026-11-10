%% @doc The behaviour a replicated state machine implements.
%%
%% The programming model is ra's. You write a deterministic state machine;
%% peace agrees on the order of commands and applies each one, in that order,
%% on every server.
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
%% `apply/3' runs on every server and must return the same thing on each. It
%% must depend on nothing but its arguments: no clock, no `rand', no `node()',
%% no process dictionary, no ETS. Anything of that kind belongs in the command,
%% decided once by whoever submits it.
%%
%% `apply/3' can run more than once for the same command on the same server: a
%% server that restarts rebuilds its state by applying its log again. That is
%% why side effects are not performed in `apply/3' but returned from it as
%% effects.
%%
%% == Effects ==
%%
%% Effects are performed only by the leader, only when a command is first
%% committed, and never during recovery.
%%
%% <ul>
%% <li>`{send_msg, Dest, Msg}' - send `Msg' to a pid or registered name.</li>
%% <li>`{mod_call, Module, Function, Args}' - call a function, result
%%   ignored. It runs in the server process, so it must not block.</li>
%% </ul>
%%
%% An effect is at-most-once per leadership and not guaranteed at all: a
%% leader that crashes between committing a command and performing its effects
%% takes them with it. `state_enter/2' is where a new leader re-issues
%% whatever it finds outstanding in the state.
-module(peace_machine).

-export([init/1, apply/4, state_enter/3]).

-export_type([machine/0, state/0, command/0, reply/0, meta/0, effect/0, effects/0]).

-type machine() :: {module, module(), Args :: term()}.
-type state() :: term().
-type command() :: term().
-type reply() :: term().
%% `index' is the command's position in the replicated log.
-type meta() :: #{index := peace:index()}.
-type effect() ::
    {send_msg, Dest :: pid() | atom() | {atom(), node()}, Msg :: term()}
    | {mod_call, module(), atom(), [term()]}.
-type effects() :: [effect()].

-callback init(Args :: term()) -> state().

-callback apply(meta(), command(), state()) ->
    {state(), reply()} | {state(), reply(), effects()}.

%% Called on the server whose role changed, with its current state. The
%% returned effects are performed whatever the role.
-callback state_enter(peace:role(), state()) -> effects().

-optional_callbacks([state_enter/2]).

%% @private
-spec init(machine()) -> state().
init({module, Mod, Args}) ->
    Mod:init(Args).

%% @private
-spec apply(machine(), meta(), command(), state()) -> {state(), reply(), effects()}.
apply({module, Mod, _Args}, Meta, Command, State) ->
    case Mod:apply(Meta, Command, State) of
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
