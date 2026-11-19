%%--------------------------------------------------------------------
%% @doc EUnit coverage for the framework-agnostic Streamable HTTP handler.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_http_handler_tests).

-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"2026-07-28">>).

missing_protocol_version_test() ->
    ?assertMatch(
        {error, 400, _},
        erlmcp_http_handler:handle(#{}, #{<<"mcp-method">> => <<"tools/list">>})
    ).

unsupported_protocol_version_test() ->
    ?assertMatch(
        {error, 400, _},
        erlmcp_http_handler:handle(#{}, headers(<<"2025-11-25">>, <<"tools/list">>))
    ).

missing_method_test() ->
    ?assertMatch(
        {error, 400, _},
        erlmcp_http_handler:handle(#{}, #{<<"mcp-protocol-version">> => ?VERSION})
    ).

header_case_variants_test() ->
    ?assertMatch(
        {ok, 200, _, _},
        erlmcp_http_handler:handle(
            request(1, <<"server/discover">>, valid_params()),
            #{
                <<"MCP-Protocol-Version">> => ?VERSION,
                <<"Mcp-Method">> => <<"server/discover">>
            }
        )
    ).

invalid_headers_argument_test() ->
    ?assertMatch(
        {error, 400, _},
        erlmcp_http_handler:handle(#{}, not_a_map, #{})
    ).

invalid_body_type_test() ->
    ?assertMatch(
        {error, 400, _},
        erlmcp_http_handler:handle(not_a_body, headers(?VERSION, <<"tools/list">>))
    ).

invalid_json_body_test() ->
    ?assertMatch(
        {error, 400, _},
        erlmcp_http_handler:handle(<<"{invalid">>, headers(?VERSION, <<"tools/list">>))
    ).

non_object_json_body_test() ->
    ?assertMatch(
        {error, 400, _},
        erlmcp_http_handler:handle(<<"[]">>, headers(?VERSION, <<"tools/list">>))
    ).

successful_discovery_test() ->
    {ok, 200, ResponseHeaders, Body} =
        erlmcp_http_handler:handle(
            request(17, <<"server/discover">>, valid_params()),
            headers(?VERSION, <<"server/discover">>)
        ),

    ?assert(lists:member(
        {<<"content-type">>, <<"application/json">>},
        ResponseHeaders
    )),
    ?assert(lists:member(
        {<<"cache-control">>, <<"no-store">>},
        ResponseHeaders
    )),
    Response = json:decode(Body),
    ?assertEqual(17, maps:get(<<"id">>, Response)),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(
        [?VERSION],
        maps:get(<<"supportedVersions">>, Result)
    ).

notification_returns_no_content_test() ->
    Notification = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/initialized">>,
        <<"params">> => valid_params()
    },
    ?assertEqual(
        {ok, 204, [], <<>>},
        erlmcp_http_handler:handle(
            Notification,
            headers(?VERSION, <<"notifications/initialized">>)
        )
    ).

jsonrpc_validation_error_is_http_success_test() ->
    InvalidRequest = #{
        <<"jsonrpc">> => <<"1.0">>,
        <<"id">> => 4,
        <<"method">> => <<"server/discover">>
    },
    {ok, 200, _Headers, Body} =
        erlmcp_http_handler:handle(
            InvalidRequest,
            headers(?VERSION, <<"server/discover">>)
        ),
    Response = json:decode(Body),
    ?assertEqual(-32600, maps:get(
        <<"code">>,
        maps:get(<<"error">>, Response)
    )).

options_argument_is_reserved_test() ->
    ?assertMatch(
        {ok, 200, _, _},
        erlmcp_http_handler:handle(
            request(2, <<"server/discover">>, valid_params()),
            headers(?VERSION, <<"server/discover">>),
            #{allowed_origins => [<<"https://example.test">>]}
        )
    ).

request(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }.

valid_params() ->
    #{<<"_meta">> => #{
        <<"io.modelcontextprotocol/protocolVersion">> => ?VERSION,
        <<"io.modelcontextprotocol/clientCapabilities">> => #{},
        <<"io.modelcontextprotocol/clientInfo">> => #{
            <<"name">> => <<"erlmcp-tests">>,
            <<"version">> => <<"0.1.0">>
        }
    }}.

headers(Version, Method) ->
    #{
        <<"mcp-protocol-version">> => Version,
        <<"mcp-method">> => Method
    }.
