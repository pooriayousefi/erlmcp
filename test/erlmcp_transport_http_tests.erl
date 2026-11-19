%%--------------------------------------------------------------------
%% @doc EUnit tests for the Streamable HTTP client transport.
%%
%% These tests cover configuration validation, lifecycle, unsupported
%% operations, and propagation of HTTP connection failures through the
%% client connection contract. Successful HTTP payload decoding is
%% exercised at the handler boundary in erlmcp_http_handler_tests.
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
        catch erlmcp_transport_http:stop(Transport)
    end.

http_connection_failure_is_reported_test() ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, {_Address, Port}} = inet:sockname(Listener),
    ok = gen_tcp:close(Listener),

    Url = iolist_to_binary([
        "http://127.0.0.1:",
        integer_to_list(Port),
        "/mcp"
    ]),
    {ok, Transport} = erlmcp_transport_http:start_link(
        Url,
        #{request_timeout => 1000}
    ),
    {ok, Connection} = erlmcp_client_connection:start_link(
        Transport,
        #{request_timeout => 2000}
    ),

    try
        Result = gen_server:call(
            Connection,
            {request, request(91)},
            3000
        ),
        ?assertMatch(
            {error, {transport_error, {http_request_failed, _}}},
            Result
        )
    after
        catch erlmcp_client_connection:stop(Connection),
        catch erlmcp_transport_http:stop(Transport)
    end.

request(Id) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"test/method">>,
        <<"params">> => #{}
    }.
