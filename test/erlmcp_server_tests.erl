
%%--------------------------------------------------------------------
%% @doc
%% EUnit tests for the stateless MCP server.
%%
%% Responsibilities:
%%   - Verify JSON-RPC validation and request dispatch.
%%   - Verify 2026-07-28 metadata enforcement.
%%   - Verify discovery and tool-list result structures.
%%   - Verify successful and failed tool invocation.
%%   - Verify that notifications never produce responses.
%%
%% Architectural role:
%%   These tests exercise erlmcp_server as the protocol-facing
%%   dispatcher, using the real registry and executor processes.
%%--------------------------------------------------------------------
-module(erlmcp_server_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PROTOCOL_VERSION, <<"2026-07-28">>).

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

invalid_jsonrpc_message_test() ->
    Result = erlmcp_server:handle_message(#{
        <<"jsonrpc">> => <<"1.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>
    }),

    ?assertMatch(
        {ok, #{<<"error">> := #{<<"code">> := -32600}}},
        Result
    ).

valid_jsonrpc_without_mcp_metadata_test() ->
    Message = request(1, <<"tools/list">>, #{}),

    Result = erlmcp_server:handle_message(Message),

    ?assertMatch(
        {ok, #{<<"error">> := #{<<"code">> := -32602}}},
        Result
    ).

unsupported_protocol_version_test() ->
    Params = #{
        <<"_meta">> => metadata(<<"2025-11-25">>)
    },

    Result = erlmcp_server:handle_message(
        request(1, <<"server/discover">>, Params)
    ),

    ?assertMatch(
        {ok, #{
            <<"error">> := #{
                <<"code">> := -32022
            }
        }},
        Result
    ).

missing_client_capabilities_test() ->
    Meta = #{
        <<"io.modelcontextprotocol/protocolVersion">> =>
            ?PROTOCOL_VERSION
    },

    Result = erlmcp_server:handle_message(
        request(1, <<"server/discover">>, #{<<"_meta">> => Meta})
    ),

    ?assertMatch(
        {ok, #{<<"error">> := #{<<"code">> := -32602}}},
        Result
    ).

server_discover_test() ->
    Result = erlmcp_server:handle_message(
        request(1, <<"server/discover">>, valid_params())
    ),

    ?assertMatch(
        {ok, #{
            <<"jsonrpc">> := <<"2.0">>,
            <<"id">> := 1,
            <<"result">> := #{
                <<"resultType">> := <<"complete">>,
                <<"supportedVersions">> := [?PROTOCOL_VERSION],
                <<"capabilities">> := #{<<"tools">> := #{}},
                <<"_meta">> := #{
                    <<"io.modelcontextprotocol/serverInfo">> := #{
                        <<"name">> := <<"erlmcp">>,
                        <<"version">> := <<"0.1.0">>
                    }
                }
            }
        }},
        Result
    ).

unknown_method_test() ->
    Result = erlmcp_server:handle_message(
        request(1, <<"unknown/method">>, valid_params())
    ),

    ?assertMatch(
        {ok, #{<<"error">> := #{<<"code">> := -32601}}},
        Result
    ).

tools_list_test_() ->
    {setup,
        fun start_services/0,
        fun stop_services/1,
        fun(_Services) ->
            ?_test(begin
                Result = erlmcp_server:handle_message(
                    request(2, <<"tools/list">>, valid_params())
                ),

                ?assertMatch(
                    {ok, #{
                        <<"result">> := #{
                            <<"resultType">> := <<"complete">>,
                            <<"tools">> := [],
                            <<"ttlMs">> := 0,
                            <<"cacheScope">> := <<"private">>,
                            <<"_meta">> := #{
                                <<"io.modelcontextprotocol/serverInfo">> :=
                                    #{}
                            }
                        }
                    }},
                    Result
                )
            end)
        end
    }.

tools_call_success_test_() ->
    {setup,
        fun start_services/0,
        fun stop_services/1,
        fun(_Services) ->
            ?_test(begin
                ok = erlmcp_tool_registry:register_tool(#{
                    name => <<"echo">>,
                    description => <<"Returns the supplied text">>,
                    input_schema => #{
                        <<"type">> => <<"object">>
                    },
                    handler => fun(Arguments) ->
                        maps:get(<<"text">>, Arguments)
                    end
                }),

                Params = (valid_params())#{
                    <<"name">> => <<"echo">>,
                    <<"arguments">> => #{
                        <<"text">> => <<"hello">>
                    }
                },

                Result = erlmcp_server:handle_message(
                    request(3, <<"tools/call">>, Params)
                ),

                ?assertMatch(
                    {ok, #{
                        <<"result">> := #{
                            <<"resultType">> := <<"complete">>,
                            <<"isError">> := false,
                            <<"content">> := [
                                #{
                                    <<"type">> := <<"text">>,
                                    <<"text">> := <<"hello">>
                                }
                            ],
                            <<"_meta">> := #{
                                <<"io.modelcontextprotocol/serverInfo">> :=
                                    #{}
                            }
                        }
                    }},
                    Result
                )
            end)
        end
    }.

tools_call_unknown_tool_test_() ->
    {setup,
        fun start_services/0,
        fun stop_services/1,
        fun(_Services) ->
            ?_test(begin
                Params = (valid_params())#{
                    <<"name">> => <<"does-not-exist">>,
                    <<"arguments">> => #{}
                },

                Result = erlmcp_server:handle_message(
                    request(4, <<"tools/call">>, Params)
                ),

                ?assertMatch(
                    {ok, #{
                        <<"result">> := #{
                            <<"resultType">> := <<"complete">>,
                            <<"isError">> := true
                        }
                    }},
                    Result
                )
            end)
        end
    }.

tools_call_handler_receives_input_context_test_() ->
    {setup,
        fun start_services/0,
        fun stop_services/1,
        fun(_Services) ->
            ?_test(begin
                Parent = self(),
                ok = erlmcp_tool_registry:register_tool(#{
                    name => <<"interactive">>,
                    input_schema => #{<<"type">> => <<"object">>},
                    handler => fun(_Arguments, Context) ->
                        Parent ! {handler_context, Context},
                        case maps:get(input_responses, Context, []) of
                            [] ->
                                #{
                                    result_type => input_required,
                                    input_requests => [
                                        #{<<"id">> => <<"approval">>}
                                    ],
                                    request_state => <<"opaque-1">>
                                };
                            [#{<<"value">> := true}] ->
                                <<"approved">>
                        end
                    end
                }),
                FirstParams = (valid_params())#{
                    <<"name">> => <<"interactive">>,
                    <<"arguments">> => #{}
                },
                {ok, FirstResponse} = erlmcp_server:handle_message(
                    request(30, <<"tools/call">>, FirstParams)
                ),
                FirstResult = maps:get(<<"result">>, FirstResponse),
                ?assertEqual(<<"input_required">>,
                             maps:get(<<"resultType">>, FirstResult)),
                ?assertEqual(<<"opaque-1">>,
                             maps:get(<<"requestState">>, FirstResult)),
                SecondParams = FirstParams#{
                    <<"inputResponses">> => [
                        #{<<"id">> => <<"approval">>, <<"value">> => true}
                    ],
                    <<"requestState">> => <<"opaque-1">>
                },
                {ok, SecondResponse} = erlmcp_server:handle_message(
                    request(31, <<"tools/call">>, SecondParams)
                ),
                ?assertMatch(
                    #{<<"result">> := #{
                        <<"resultType">> := <<"complete">>,
                        <<"isError">> := false
                    }},
                    SecondResponse
                ),
                receive
                    {handler_context, Context1} ->
                        ?assertEqual(#{}, Context1)
                after 1000 -> ?assert(false)
                end,
                receive
                    {handler_context, Context2} ->
                        ?assertEqual(
                            [#{<<"id">> => <<"approval">>,
                               <<"value">> => true}],
                            maps:get(input_responses, Context2)
                        ),
                        ?assertEqual(<<"opaque-1">>,
                                     maps:get(request_state, Context2))
                after 1000 -> ?assert(false)
                end
            end)
        end
    }.

tools_call_invalid_params_test() ->
    Params = (valid_params())#{
        <<"name">> => 42,
        <<"arguments">> => #{}
    },

    Result = erlmcp_server:handle_message(
        request(5, <<"tools/call">>, Params)
    ),

    ?assertMatch(
        {ok, #{<<"error">> := #{<<"code">> := -32602}}},
        Result
    ).

notification_returns_no_response_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/unknown">>,
        <<"params">> => valid_params()
    },

    ?assertEqual(
        no_response,
        erlmcp_server:handle_message(Message)
    ).

client_response_is_not_accepted_by_server_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 10,
        <<"result">> => #{}
    },

    ?assertEqual(
        {error, unexpected_client_response},
        erlmcp_server:handle_message(Message)
    ).

%%--------------------------------------------------------------------
%% Test helpers
%%--------------------------------------------------------------------

request(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }.

valid_params() ->
    #{
        <<"_meta">> => metadata(?PROTOCOL_VERSION)
    }.

metadata(Version) ->
    #{
        <<"io.modelcontextprotocol/protocolVersion">> => Version,
        <<"io.modelcontextprotocol/clientCapabilities">> => #{},
        <<"io.modelcontextprotocol/clientInfo">> => #{
            <<"name">> => <<"erlmcp-tests">>,
            <<"version">> => <<"0.1.0">>
        }
    }.

start_services() ->
    {ok, Registry} = erlmcp_tool_registry:start_link(),
    unlink(Registry),

    {ok, Executor} = erlmcp_tool_executor:start_link(),
    unlink(Executor),

    {Registry, Executor}.

stop_services({Registry, Executor}) ->
    try gen_server:stop(Executor)
    catch
        _:_ -> ok
    end,

    try gen_server:stop(Registry)
    catch
        _:_ -> ok
    end,

    ok.
