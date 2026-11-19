%%--------------------------------------------------------------------
%% @doc EUnit tests for the Streamable HTTP client transport.
%%
%% These tests cover configuration validation, lifecycle, unsupported
%% operations, and HTTP error propagation through the client connection.
%% Successful HTTP payload decoding is exercised at the handler boundary
%% in erlmcp_http_handler_tests.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_transport_http_tests).

-include_lib("eunit/include/eunit.hrl").

invalid_empty_url_test() ->
    ?assertEqual(
        {error, invalid_url},
        erlmcp_transport_http:start_link(<<>>)
    ).

invalid_url_type_test() ->
    ?assertEqual(
        {error, invalid_url},
        erlmcp_transport_http:start_link(42)
    ).

invalid_options_type_test() ->
    ?assertEqual(
        {error, invalid_options},
        erlmcp_transport_http:start_link(<<"http://127.0.0.1:1/mcp">>, [])
    ).

start_stop_test() ->
    {ok, Transport} =
        erlmcp_transport_http:start_link(<<"http://127.0.0.1:1/mcp">>),
    ?assert(is_process_alive(Transport)),
    ?assertEqual(ok, erlmcp_transport_http:stop(Transport)),
    ?assertNot(is_process_alive(Transport)).

unsupported_call_test() ->
    {ok, Transport} =
        erlmcp_transport_http:start_link(<<"http://127.0.0.1:1/mcp">>),
    try
        ?assertEqual(
            {error, unsupported_operation},
            gen_server:call(Transport, unsupported)
        )
    after
        stop_safely(fun() -> erlmcp_transport_http:stop(Transport) end)
    end.

http_error_response_is_reported_test() ->
    {ok, Listener} = gen_tcp:listen(
        0,
        [binary, {active, false}, {reuseaddr, true}]
    ),
    {ok, {_Address, Port}} = inet:sockname(Listener),
    Server = spawn(fun() -> serve_http_error(Listener) end),

    Url = iolist_to_binary([
        "http://127.0.0.1:",
        integer_to_list(Port),
        "/mcp"
    ]),
    {ok, Transport} = erlmcp_transport_http:start_link(Url),
    {ok, Connection} = erlmcp_client_connection:start_link(
        Transport,
        #{request_timeout => 3000}
    ),

    try
        Result = gen_server:call(
            Connection,
            {request, request(91)},
            4000
        ),
        ?assertMatch(
            {error, {transport_error, {http_error, 503, _}}},
            Result
        ),
        ?assertNot(is_process_alive(Server))
    after
        stop_safely(fun() -> erlmcp_client_connection:stop(Connection) end),
        stop_safely(fun() -> erlmcp_transport_http:stop(Transport) end),
        stop_safely(fun() -> gen_tcp:close(Listener) end),
        stop_safely(fun() -> exit(Server, kill) end)
    end.

serve_http_error(Listener) ->
    case gen_tcp:accept(Listener, 3000) of
        {ok, Socket} ->
            _ = gen_tcp:recv(Socket, 0, 2000),
            _ = gen_tcp:send(
                Socket,
                <<"HTTP/1.1 503 Service Unavailable\r\n",
                  "Content-Length: 0\r\n",
                  "Connection: close\r\n\r\n">>
            ),
            _ = gen_tcp:close(Socket),
            _ = gen_tcp:close(Listener),
            ok;
        {error, _Reason} ->
            _ = gen_tcp:close(Listener),
            ok
    end.

stop_safely(Fun) ->
    try Fun() catch _:_ -> ok end.

request(Id) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"test/method">>,
        <<"params">> => #{}
    }.
