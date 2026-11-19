
%%--------------------------------------------------------------------
%% @doc
%% EUnit tests for the stateless MCP client.
%%
%% Responsibilities:
%%   - Verify discovery, tool listing, and tool invocation.
%%   - Verify request metadata and optional request fields.
%%   - Verify JSON-RPC response correlation and error handling.
%%   - Verify MCP result validation, including input_required results.
%%
%% Architectural role:
%%   A small test-only gen_server simulates the future client
%%   connection module. It receives complete JSON-RPC requests and
%%   returns configured JSON-RPC responses. No transport is involved.
%%--------------------------------------------------------------------
-module(erlmcp_client_tests).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(PROTOCOL_VERSION, <<"2026-07-28">>).

%%--------------------------------------------------------------------
%% Discovery tests
%%--------------------------------------------------------------------

discover_test() ->
    with_connection(
        fun(Request) ->
            ?assertEqual(
                <<"server/discover">>,
                maps:get(<<"method">>, Request)
            ),

            Meta = maps:get(
                <<"_meta">>,
                maps:get(<<"params">>, Request)
            ),

            ?assertEqual(
                ?PROTOCOL_VERSION,
                maps:get(
                    <<"io.modelcontextprotocol/protocolVersion">>,
                    Meta
                )
            ),

            jsonrpc_response(Request, discovery_result())
        end,
        fun(Connection) ->
            ?assertMatch({ok, _}, erlmcp_client:discover(Connection))
        end
    ).

discover_unsupported_version_test() ->
    with_connection(
        fun(Request) ->
            Result = (discovery_result())#{
                <<"supportedVersions">> => [<<"2025-11-25">>]
            },
            jsonrpc_response(Request, Result)
        end,
        fun(Connection) ->
            ?assertEqual(
                {error, {unsupported_protocol_version, [<<"2025-11-25">>]}},
                erlmcp_client:discover(Connection)
            )
        end
    ).

discover_invalid_result_test() ->
    with_connection(
        fun(Request) ->
            jsonrpc_response(Request, #{
                <<"resultType">> => <<"complete">>,
                <<"supportedVersions">> => [<<"unsupported-version">>],
                <<"capabilities">> => #{},
                <<"_meta">> => server_meta()
            })
        end,
        fun(Connection) ->
            ?assertEqual(
                {error, {unsupported_protocol_version, [<<"unsupported-version">>]}},
                erlmcp_client:discover(Connection)
            )
        end
    ).

%%--------------------------------------------------------------------
%% Tool-list tests
%%--------------------------------------------------------------------

list_tools_test() ->
    Tool = #{
        <<"name">> => <<"echo">>,
        <<"description">> => <<"Echo input">>,
        <<"inputSchema">> => #{
            <<"type">> => <<"object">>
        }
    },

    with_connection(
        fun(Request) ->
            ?assertEqual(
                <<"tools/list">>,
                maps:get(<<"method">>, Request)
            ),
            jsonrpc_response(Request, tools_list_result([Tool]))
        end,
        fun(Connection) ->
            ?assertEqual(
                {ok, tools_list_result([Tool])},
                erlmcp_client:list_tools(Connection)
            )
        end
    ).

list_tools_with_cursor_test() ->
    Parent = self(),

    with_connection(
        fun(Request) ->
            Params = maps:get(<<"params">>, Request),
            Parent ! {received_cursor, maps:get(<<"cursor">>, Params)},
            jsonrpc_response(Request, tools_list_result([]))
        end,
        fun(Connection) ->
            ?assertMatch(
                {ok, _},
                erlmcp_client:list_tools(Connection, #{
                    cursor => <<"page-2">>
                })
            ),
            receive
                {received_cursor, Cursor} ->
                    ?assertEqual(<<"page-2">>, Cursor)
            after 1000 ->
                ?assert(false)
            end
        end
    ).

list_tools_invalid_definition_test() ->
    with_connection(
        fun(Request) ->
            Result = tools_list_result([
                #{<<"name">> => <<"broken">>}
            ]),
            jsonrpc_response(Request, Result)
        end,
        fun(Connection) ->
            ?assertEqual(
                {error, invalid_tool_definition},
                erlmcp_client:list_tools(Connection)
            )
        end
    ).

%%--------------------------------------------------------------------
%% Tool invocation tests
%%--------------------------------------------------------------------

call_tool_test() ->
    Parent = self(),

    ToolResult = #{
        <<"resultType">> => <<"complete">>,
        <<"content">> => [
            #{
                <<"type">> => <<"text">>,
                <<"text">> => <<"hello">>
            }
        ],
        <<"isError">> => false,
        <<"_meta">> => server_meta()
    },

    with_connection(
        fun(Request) ->
            ?assertEqual(
                <<"tools/call">>,
                maps:get(<<"method">>, Request)
            ),

            Params = maps:get(<<"params">>, Request),
            Parent ! {received_tool_params, Params},

            jsonrpc_response(Request, ToolResult)
        end,
        fun(Connection) ->
            ?assertEqual(
                {ok, ToolResult},
                erlmcp_client:call_tool(
                    Connection,
                    <<"echo">>,
                    #{<<"text">> => <<"hello">>}
                )
            ),

            receive
                {received_tool_params, Params} ->
                    ?assertEqual(
                        <<"echo">>,
                        maps:get(<<"name">>, Params)
                    ),
                    ?assertEqual(
                        #{<<"text">> => <<"hello">>},
                        maps:get(<<"arguments">>, Params)
                    ),
                    ?assert(maps:is_key(<<"_meta">>, Params))
            after 1000 ->
                ?assert(false)
            end
        end
    ).

call_tool_input_required_test() ->
    InputRequired = #{
        <<"resultType">> => <<"input_required">>,
        <<"inputRequests">> => [
            #{<<"type">> => <<"example">>}
        ],
        <<"requestState">> => <<"opaque-state">>,
        <<"_meta">> => server_meta()
    },

    with_connection(
        fun(Request) ->
            jsonrpc_response(Request, InputRequired)
        end,
        fun(Connection) ->
            ?assertEqual(
                {ok, InputRequired},
                erlmcp_client:call_tool(
                    Connection,
                    <<"interactive-tool">>,
                    #{}
                )
            )
        end
    ).

call_tool_preserves_multi_round_trip_fields_test() ->
    Parent = self(),

    with_connection(
        fun(Request) ->
            Parent ! {received_request, maps:get(<<"params">>, Request)},
            jsonrpc_response(Request, #{
                <<"resultType">> => <<"complete">>,
                <<"content">> => [],
                <<"isError">> => false,
                <<"_meta">> => server_meta()
            })
        end,
        fun(Connection) ->
            ?assertMatch(
                {ok, _},
                erlmcp_client:call_tool(
                    Connection,
                    <<"interactive-tool">>,
                    #{},
                    #{
                        input_responses => [#{<<"answer">> => <<"yes">>}],
                        request_state => <<"opaque-state">>
                    }
                )
            ),

            receive
                {received_request, Params} ->
                    ?assertEqual(
                        [#{<<"answer">> => <<"yes">>}],
                        maps:get(<<"inputResponses">>, Params)
                    ),
                    ?assertEqual(
                        <<"opaque-state">>,
                        maps:get(<<"requestState">>, Params)
                    )
            after 1000 ->
                ?assert(false)
            end
        end
    ).

call_tool_invalid_arguments_test() ->
    ?assertEqual(
        {error, invalid_arguments},
        erlmcp_client:call_tool(
            self(),
            <<"echo">>,
            invalid_arguments
        )
    ).

%%--------------------------------------------------------------------
%% JSON-RPC response validation tests
%%--------------------------------------------------------------------

response_id_mismatch_test() ->
    Response = erlmcp_jsonrpc:response(99, #{}),

    ?assertEqual(
        {error, {response_id_mismatch, 1, 99}},
        erlmcp_client:validate_response(1, Response)
    ).

remote_error_response_test() ->
    Response = erlmcp_jsonrpc:error(
        1,
        -32601,
        <<"Method not found">>,
        undefined
    ),

    ?assertMatch(
        {error, {remote_error, #{<<"code">> := -32601}}},
        erlmcp_client:validate_response(1, Response)
    ).

invalid_jsonrpc_response_test() ->
    ?assertMatch(
        {error, {invalid_jsonrpc_response, _}},
        erlmcp_client:validate_response(
            1,
            #{<<"jsonrpc">> => <<"1.0">>}
        )
    ).

%%--------------------------------------------------------------------
%% Test-only connection process
%%--------------------------------------------------------------------

with_connection(ResponseFun, TestFun) ->
    {ok, Connection} = gen_server:start_link(
        ?MODULE,
        ResponseFun,
        []
    ),

    try
        TestFun(Connection)
    after
        try gen_server:stop(Connection)
        catch
            _:_ -> ok
        end
    end.

init(ResponseFun) ->
    {ok, ResponseFun}.

handle_call({request, Request}, _From, ResponseFun) ->
    {reply, ResponseFun(Request), ResponseFun};

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Fixtures
%%--------------------------------------------------------------------

jsonrpc_response(Request, Result) ->
    erlmcp_jsonrpc:response(
        maps:get(<<"id">>, Request),
        Result
    ).

discovery_result() ->
    #{
        <<"resultType">> => <<"complete">>,
        <<"supportedVersions">> => [?PROTOCOL_VERSION],
        <<"capabilities">> => #{
            <<"tools">> => #{}
        },
        <<"ttlMs">> => 0,
        <<"cacheScope">> => <<"private">>,
        <<"_meta">> => server_meta()
    }.

tools_list_result(Tools) ->
    #{
        <<"resultType">> => <<"complete">>,
        <<"tools">> => Tools,
        <<"ttlMs">> => 0,
        <<"cacheScope">> => <<"private">>,
        <<"_meta">> => server_meta()
    }.

server_meta() ->
    #{
        <<"io.modelcontextprotocol/serverInfo">> => #{
            <<"name">> => <<"test-server">>,
            <<"version">> => <<"1.0.0">>
        }
    }.
