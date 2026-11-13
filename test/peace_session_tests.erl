%% These tests run a session process against servers that the test plays.
%% Each test registers its own process under the names of the servers,
%% reads the casts that the session process sends, and sends the replies.
-module(peace_session_tests).

-include_lib("eunit/include/eunit.hrl").

-define(RETRY_MS, 500).

%% The session process sends the values of a window in order. A further
%% value waits until a value of the window has a reply.
window_test() ->
    {S, [A | _]} = open(#{window => 2}),
    Refs = [R1, R2, R3] = cast_all(S, [v1, v2]) ++ [cast_async(S, v3)],
    {A, L1, v1, {Id, 1}} = sent(),
    {A, L2, v2, {Id, 2}} = sent(),
    nothing = sent(100),
    answer(S, L2, {ok, r2, A}),
    {ok, r2} = result(R2),
    %% The lowest value has no reply, so the window is still full.
    nothing = sent(100),
    answer(S, L1, {ok, r1, A}),
    {ok, r1} = result(R1),
    {A, L3, v3, {Id, 3}} = sent(),
    answer(S, L3, {ok, r3, A}),
    {ok, r3} = result(R3),
    ?assertEqual(3, length(Refs)),
    close(S).

%% After a gap, the session process sends every value that has no reply
%% again, in order. The further gap replies of the same round start no
%% further round.
gap_test() ->
    {S, [A | _]} = open(#{}),
    [R1, R2, R3] = cast_all(S, [v1, v2, v3]),
    [{A, L1, v1, _}, {A, L2, v2, _}, {A, L3, v3, _}] = [sent() || _ <- [1, 2, 3]],
    answer(S, L1, {ok, r1, A}),
    {ok, r1} = result(R1),
    %% The server lost v2.
    answer(S, L3, {error, {session_gap, 1}}),
    [{A, M2, v2, {_, 2}}, {A, M3, v3, {_, 3}}] = [sent() || _ <- [1, 2]],
    %% A reply of the earlier round.
    answer(S, L2, {error, {session_gap, 1}}),
    nothing = sent(100),
    answer(S, M2, {ok, r2, A}),
    answer(S, M3, {ok, r3, A}),
    [{ok, r2}, {ok, r3}] = [result(R) || R <- [R2, R3]],
    close(S).

%% An `ok' reply of an earlier round is used.
late_ok_test() ->
    {S, [A | _]} = open(#{}),
    [R1] = cast_all(S, [v1]),
    {A, L1, v1, _} = sent(),
    answer(S, L1, {error, overloaded}),
    {A, _M1, v1, _} = sent(),
    answer(S, L1, {ok, r1, A}),
    {ok, r1} = result(R1),
    close(S).

%% The session process follows a `not_leader' reply that names a leader.
%% When no reply arrives in the retry time, the session process changes to
%% the next server.
leader_test() ->
    {S, [A, B, C]} = open(#{}),
    [R1] = cast_all(S, [v1]),
    {A, L1, v1, _} = sent(),
    answer(S, L1, {error, {not_leader, C}}),
    {C, _Lost, v1, _} = sent(),
    %% C does not answer. The next server after C is A.
    {A, L2, v1, _} = sent(?RETRY_MS * 3),
    answer(S, L2, {error, {not_leader, undefined}}),
    {B, L3, v1, _} = sent(?RETRY_MS * 3),
    answer(S, L3, {ok, r1, B}),
    {ok, r1} = result(R1),
    %% The next value goes to the server that answered.
    {ok, r2} = call_with(S, v2, fun({To, L, v2, _}) -> answer(S, L, {ok, r2, To}), ?assertEqual(B, To) end),
    close(S).

%% The cluster evicted the session. The values without a reply are answered
%% `session_evicted'. The next value uses a new client id and sequence
%% number 1.
eviction_test() ->
    {S, [A | _]} = open(#{}),
    [R1, R2, R3] = cast_all(S, [v1, v2, v3]),
    [{A, L1, v1, {Id, 1}}, {A, L2, v2, _}, {A, _L3, v3, _}] = [sent() || _ <- [1, 2, 3]],
    answer(S, L1, {ok, r1, A}),
    {ok, r1} = result(R1),
    answer(S, L2, {error, {session_gap, 1}}),
    [{A, M2, v2, _}, {A, _M3, v3, _}] = [sent() || _ <- [1, 2]],
    answer(S, M2, {error, {session_gap, 0}}),
    [{error, session_evicted}, {error, session_evicted}] = [result(R) || R <- [R2, R3]],
    [R4] = cast_all(S, [v4]),
    {A, L4, v4, {Id4, 1}} = sent(),
    ?assertNotEqual(Id, Id4),
    answer(S, L4, {ok, r4, A}),
    {ok, r4} = result(R4),
    close(S).

%% A session that has received no reply is not evicted. `session_gap' with
%% 0 is then an ordinary gap.
gap_at_start_test() ->
    {S, [A | _]} = open(#{}),
    [R1, R2] = cast_all(S, [v1, v2]),
    [{A, _L1, v1, _}, {A, L2, v2, _}] = [sent() || _ <- [1, 2]],
    answer(S, L2, {error, {session_gap, 0}}),
    [{A, M1, v1, {Id, 1}}, {A, M2, v2, {Id, 2}}] = [sent() || _ <- [1, 2]],
    answer(S, M1, {ok, r1, A}),
    answer(S, M2, {ok, r2, A}),
    [{ok, r1}, {ok, r2}] = [result(R) || R <- [R1, R2]],
    close(S).

%% A value that was applied and whose reply the cluster no longer holds.
superseded_test() ->
    {S, [A | _]} = open(#{}),
    [R1] = cast_all(S, [v1]),
    {A, L1, v1, _} = sent(),
    answer(S, L1, {error, {session_superseded, 70}}),
    {error, {session_superseded, 70}} = result(R1),
    close(S).

%% A call that times out leaves its value in the session. Closing the
%% session answers the values that have no reply.
timeout_and_close_test() ->
    {S, [A | _]} = open(#{window => 1}),
    {timeout, S} = peace:call(S, v1, 50),
    {A, _L1, v1, _} = sent(),
    Self = self(),
    Caller = spawn_link(fun() -> Self ! {called, peace:call(S, v2, 5000)} end),
    Ref = cast_async(S, v3),
    nothing = sent(100),
    unlink(S),
    ok = peace:close_session(S),
    receive
        {called, Called} -> ?assertEqual({error, session_closed}, Called)
    after 2000 -> error({no_reply, Caller})
    end,
    {error, session_closed} = result(Ref),
    ?assertEqual({error, session_closed}, peace:call(S, v4, 50)),
    {error, session_closed} = result(peace:cast(S, v5)),
    unregister_all().

%% ---------------------------------------------------------------------------

open(Opts) ->
    unregister_all(),
    Servers = [{Name, node()} || Name <- [peace_session_t_a, peace_session_t_b, peace_session_t_c]],
    Parent = self(),
    lists:foreach(
        fun(Server = {Name, _}) ->
            true = register(Name, spawn_link(fun() -> forward_loop(Server, Parent) end))
        end,
        Servers
    ),
    {ok, S} = peace:open_session(Servers, Opts#{retry_ms => ?RETRY_MS}),
    put(session, S),
    {S, Servers}.

forward_loop(Server, Parent) ->
    receive
        {'$gen_cast', {value, {peace_session, _Pid, Label}, Value, Session}} ->
            Parent ! {sent, Server, Label, Value, Session},
            forward_loop(Server, Parent)
    end.

%% Stops the session process and the server processes that an earlier test
%% left, if that test failed.
unregister_all() ->
    case erase(session) of
        undefined ->
            ok;
        Left ->
            unlink(Left),
            exit(Left, kill)
    end,
    lists:foreach(
        fun(Name) ->
            case whereis(Name) of
                undefined ->
                    ok;
                Pid ->
                    unlink(Pid),
                    exit(Pid, kill),
                    catch unregister(Name)
            end
        end,
        [peace_session_t_a, peace_session_t_b, peace_session_t_c]
    ),
    flush().

flush() ->
    receive
        {sent, _, _, _, _} -> flush()
    after 0 -> ok
    end.

close(S) ->
    unlink(S),
    ok = peace:close_session(S),
    unregister_all().

sent() ->
    case sent(2000) of
        nothing -> error(nothing_sent);
        Sent -> Sent
    end.

sent(Ms) ->
    receive
        {sent, Server, Label, Value, Session} -> {Server, Label, Value, Session}
    after Ms -> nothing
    end.

answer(S, Label, Reply) ->
    S ! {peace_session_reply, Label, Reply},
    ok.

cast_all(S, Values) ->
    [peace:cast(S, Value) || Value <- Values].

%% Submits a value from another process, because `peace:cast/2' waits while
%% the window is full.
cast_async(S, Value) ->
    Self = self(),
    Ref = make_ref(),
    _ = spawn_link(fun() ->
        Inner = peace:cast(S, Value),
        receive
            {peace_reply, Inner, Result} -> Self ! {peace_reply, Ref, Result}
        end
    end),
    %% The session process has the value before this function returns.
    timer:sleep(50),
    Ref.

call_with(S, Value, Serve) ->
    Self = self(),
    _ = spawn_link(fun() -> Self ! {called, peace:call(S, Value, 2000)} end),
    Serve(sent()),
    receive
        {called, Result} -> Result
    after 2000 -> error(no_reply)
    end.

result(Ref) ->
    receive
        {peace_reply, Ref, Result} -> Result
    after 2000 -> error(no_result)
    end.
