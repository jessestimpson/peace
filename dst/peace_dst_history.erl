%% @doc The client history of a simulated run, for an external
%% linearizability checker.
%%
%% `peace_dst' checks linearizability with its own invariants. This module
%% exports what the clients observed, so that a checker that shares no code
%% with peace can check the same runs. The checker is Porcupine. See
%% `dst/porcupine/main.go' and `peace_dst_porcupine_tests'.
%%
%% `history => Table' in the configuration of a run names an ETS table that
%% the caller owns. When the run ends, the harness copies the history into
%% the table.
%%
%% A history is a list of events in the order in which they happened. Each
%% client performs one operation, so an operation is the pair of events of
%% one client:
%%
%% <ul>
%% <li>`{invoke, Client, {append, Value}}' and `{invoke, Client, read}'.</li>
%% <li>`{return, Client, {ok, Index}}': the value was appended at
%%   `Index'.</li>
%% <li>`{return, Client, {ok, Values}}': the read returned `Values', newest
%%   first.</li>
%% <li>`{return, Client, {rejected, Reason}}': the operation was never
%%   submitted.</li>
%% <li>`{return, Client, {unknown, Reason}}': the client does not know
%%   whether the operation happened.</li>
%% </ul>
%%
%% An operation that was still in progress when the run ended has no return
%% event.
-module(peace_dst_history).

-export([copy/2, events/1, write/2]).

%% Copies the history from the table of the harness to the table of the
%% caller.
copy(_Tab, undefined) ->
    ok;
copy(Tab, Table) ->
    true = ets:insert(Table, [{Seq, Event} || [Seq, Event] <- ets:match(Tab, {{history, '$1'}, '$2'})]),
    ok.

%% Returns the events in order.
events(Table) ->
    [Event || {_Seq, Event} <- lists:sort(ets:tab2list(Table))].

%% Writes the history as a JSON array, one object per event. A read lists
%% its values oldest first.
write(File, Events) ->
    ok = filelib:ensure_dir(File),
    Objects = [object(Seq, Event) || {Seq, Event} <- lists:zip(lists:seq(1, length(Events)), Events)],
    file:write_file(File, json:encode(Objects)).

object(Seq, {invoke, Client, {append, Value}}) ->
    #{seq => Seq, client => Client, type => invoke, op => append, value => Value};
object(Seq, {invoke, Client, read}) ->
    #{seq => Seq, client => Client, type => invoke, op => read};
object(Seq, {return, Client, {ok, Index}}) when is_integer(Index) ->
    #{seq => Seq, client => Client, type => ok, index => Index};
object(Seq, {return, Client, {ok, Values}}) when is_list(Values) ->
    #{seq => Seq, client => Client, type => ok, values => lists:reverse(Values)};
object(Seq, {return, Client, {rejected, _Reason}}) ->
    #{seq => Seq, client => Client, type => fail};
object(Seq, {return, Client, {unknown, _Reason}}) ->
    #{seq => Seq, client => Client, type => info}.
