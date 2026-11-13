%% @doc The HTTP interface of a key-value node, for the Jepsen test.
%%
%% The server handles one request per connection. A request has no body.
%% The parameters are in the query string. Keys and values are integers.
%%
%% Requests:
%%
%% <ul>
%% <li>`GET /kv/Key' is a linearizable read
%%   (`peace:consistent_query/3').</li>
%% <li>`PUT /kv/Key?value=V' stores `V'.</li>
%% <li>`PUT /kv/Key?value=V&expected=E' stores `V' if the value of the key
%%   is `E'.</li>
%% <li>`GET /status' returns the role, the leader and the members that this
%%   node knows.</li>
%% <li>`POST /members?nodes=N1,N2,N3' changes the members of the cluster to
%%   the listed nodes. The optional parameter `quorum' sets the quorum
%%   system, in the syntax of the `quorum' argument of `peace_kv_node'. The
%%   default is `majority'.</li>
%% </ul>
%%
%% Every request is sent to the peace server of this node. The request
%% follows redirects to the leader.
%%
%% If the node has a session process, a `PUT' is submitted through the
%% session process. A `PUT' is then never answered 503. A `PUT' that is
%% answered 504 stays in the session, and the session process submits it
%% until it is applied.
%%
%% Status codes:
%%
%% <ul>
%% <li>200: the read found the value. The body is the value.</li>
%% <li>204: the write or the membership change was applied.</li>
%% <li>404: the key has no value. For a compare-and-swap, the value was not
%%   stored.</li>
%% <li>409: the compare-and-swap found another value. The value was not
%%   stored.</li>
%% <li>503: the request was not submitted. It did not happen.</li>
%% <li>504: the outcome is unknown. The request may have happened, or may
%%   happen later.</li>
%% <li>400: the request is malformed.</li>
%% </ul>
-module(peace_kv_http).

-export([start/1]).

-define(TIMEOUT_MS, 5000).

%% Starts the server. Returns the pid of the process that accepts
%% connections.
start(Port) ->
    {ok, Listen} = gen_tcp:listen(Port, [binary, {packet, http_bin}, {active, false}, {reuseaddr, true}, {backlog, 256}]),
    Pid = spawn(fun() -> accept(Listen) end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    {ok, Pid}.

accept(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Pid = spawn(fun() ->
                receive
                    go -> connection(Socket)
                end
            end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Pid ! go,
            accept(Listen);
        {error, closed} ->
            ok
    end.

connection(Socket) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_request, Method, {abs_path, Target}, _Version}} ->
            ok = skip_headers(Socket),
            {Status, Body} =
                try
                    request(Method, uri_string:parse(Target))
                catch
                    _:_ -> {400, <<"bad request">>}
                end,
            _ = gen_tcp:send(Socket, response(Status, Body)),
            gen_tcp:close(Socket);
        _ ->
            gen_tcp:close(Socket)
    end.

skip_headers(Socket) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} -> ok;
        {ok, {http_header, _, _, _, _}} -> skip_headers(Socket);
        _ -> ok
    end.

request('GET', #{path := <<"/kv/", Key/binary>>}) ->
    Read =
        case peace_kv_node:reads() of
            consistent -> fun peace_kv:read/3;
            stale -> fun peace_kv:stale_read/3
        end,
    case Read(peace_kv_node:server(), binary_to_integer(Key), ?TIMEOUT_MS) of
        {ok, {ok, Value}, _Leader} -> {200, integer_to_binary(Value)};
        {ok, not_found, _Leader} -> {404, <<"not found">>};
        Other -> failure(Other)
    end;
request('PUT', #{path := <<"/kv/", Key0/binary>>, query := Query}) ->
    Key = binary_to_integer(Key0),
    Write =
        case maps:from_list(uri_string:dissect_query(Query)) of
            #{<<"value">> := Value, <<"expected">> := Expected} ->
                {cas, Key, binary_to_integer(Expected), binary_to_integer(Value)};
            #{<<"value">> := Value} ->
                {put, Key, binary_to_integer(Value)}
        end,
    Result =
        case peace_kv_node:session() of
            undefined ->
                peace:propose(peace_kv_node:server(), Write, ?TIMEOUT_MS);
            Session ->
                case peace:call(Session, Write, ?TIMEOUT_MS) of
                    {ok, Reply} -> {ok, Reply, undefined};
                    Other0 -> Other0
                end
        end,
    case Result of
        {ok, ok, _Leader} -> {204, <<>>};
        {ok, {error, not_found}, _Leader} -> {404, <<"not found">>};
        {ok, {error, {mismatch, _Current}}, _Leader} -> {409, <<"mismatch">>};
        Other -> failure(Other)
    end;
request('GET', #{path := <<"/status">>}) ->
    case peace:overview(peace_kv_node:server()) of
        #{role := Role, leader := Leader, members := Members, commit_index := Commit} ->
            {200, iolist_to_binary(io_lib:format("~0p", [{Role, Leader, Members, Commit}]))};
        Other ->
            failure(Other)
    end;
request('POST', #{path := <<"/members">>, query := Query}) ->
    Params = #{<<"nodes">> := Nodes} = maps:from_list(uri_string:dissect_query(Query)),
    Members = peace_kv_node:members(binary_to_list(Nodes)),
    Quorum = peace_kv_node:quorum(binary_to_list(maps:get(<<"quorum">>, Params, <<"majority">>))),
    case peace:change_members(peace_kv_node:server(), Members, Quorum, ?TIMEOUT_MS) of
        {ok, ok, _Leader} -> {204, <<>>};
        Other -> failure(Other)
    end;
request(_Method, _Target) ->
    {400, <<"bad request">>}.

%% The answers that mean that the request was not submitted are 503. Every
%% other failure has an unknown outcome and is 504. See `peace:propose/3'.
failure({error, Reason}) when
    Reason =:= no_leader; Reason =:= noproc; Reason =:= too_many_redirects; Reason =:= overloaded
->
    {503, atom_to_binary(Reason)};
failure({error, reconfiguration_in_progress}) ->
    {503, <<"reconfiguration_in_progress">>};
failure(Other) ->
    {504, iolist_to_binary(io_lib:format("~0p", [Other]))}.

response(Status, Body) ->
    [
        <<"HTTP/1.1 ">>,
        integer_to_binary(Status),
        <<" ">>,
        reason(Status),
        <<"\r\nContent-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\nConnection: close\r\n\r\n">>,
        Body
    ].

reason(200) -> <<"OK">>;
reason(204) -> <<"No Content">>;
reason(400) -> <<"Bad Request">>;
reason(404) -> <<"Not Found">>;
reason(409) -> <<"Conflict">>;
reason(503) -> <<"Service Unavailable">>;
reason(504) -> <<"Gateway Timeout">>.
