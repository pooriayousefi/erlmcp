
-module(erlmcp_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%% ------------------------------------------------------------------
%% Protocol identity
%% ------------------------------------------------------------------

protocol_version_test() ->
    ?assertEqual(
        <<"2026-07-28">>,
        erlmcp_protocol:protocol_version()
    ).

client_info_test() ->
    ?assertEqual(
        #{
            <<"name">> => <<"erlmcp">>,
            <<"version">> => <<"0.1.0">>
        },
        erlmcp_protocol:client_info()
    ).

client_capabilities_test() ->
    ?assertEqual(
        #{},
        erlmcp_protocol:client_capabilities()
    ).

request_meta_test() ->
    Meta = erlmcp_protocol:request_meta(),

    ?assertEqual(
        <<"2026-07-28">>,
        maps:get(<<"io.modelcontextprotocol/protocolVersion">>, Meta)
    ),

    ?assertEqual(
        erlmcp_protocol:client_capabilities(),
        maps:get(<<"io.modelcontextprotocol/clientCapabilities">>, Meta)
    ),

    ?assertEqual(
        erlmcp_protocol:client_info(),
        maps:get(<<"io.modelcontextprotocol/clientInfo">>, Meta)
    ).

server_info_test() ->
    ?assertEqual(
        #{
            <<"name">> => <<"erlmcp">>,
            <<"version">> => <<"0.1.0">>
        },
        erlmcp_protocol:server_info()
    ).

%% ------------------------------------------------------------------
%% Client requests
%% ------------------------------------------------------------------

tools_list_request_without_cursor_test() ->
    Request = erlmcp_protocol:tools_list_request(#{id => 1}),

    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"method">> => <<"tools/list">>,
            <<"params">> => #{
                <<"_meta">> => erlmcp_protocol:request_meta()
            }
        },
        Request
    ).

tools_list_request_with_cursor_test() ->
    Cursor = <<"page-2">>,

    Request = erlmcp_protocol:tools_list_request(#{
        id => 2,
        cursor => Cursor
    }),

    Params = maps:get(<<"params">>, Request),

    ?assertEqual(
        Cursor,
        maps:get(<<"cursor">>, Params)
    ),

    ?assertEqual(
        erlmcp_protocol:request_meta(),
        maps:get(<<"_meta">>, Params)
    ).

tools_call_request_minimal_test() ->
    Request = erlmcp_protocol:tools_call_request(#{
        id => 3,
        name => <<"get_time">>
    }),

    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 3,
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{
                <<"name">> => <<"get_time">>,
                <<"arguments">> => #{},
                <<"_meta">> => erlmcp_protocol:request_meta()
            }
        },
        Request
    ).

tools_call_request_with_arguments_test() ->
    Arguments = #{
        <<"timezone">> => <<"UTC">>
    },

    Request = erlmcp_protocol:tools_call_request(#{
        id => 4,
        name => <<"get_time">>,
        arguments => Arguments
    }),

    Params = maps:get(<<"params">>, Request),

    ?assertEqual(
        Arguments,
        maps:get(<<"arguments">>, Params)
    ).

tools_call_request_with_input_responses_test() ->
    InputResponses = [
        #{
            <<"id">> => <<"confirmation">>,
            <<"value">> => true
        }
    ],

    Request = erlmcp_protocol:tools_call_request(#{
        id => 5,
        name => <<"delete_file">>,
        input_responses => InputResponses
    }),

    Params = maps:get(<<"params">>, Request),

    ?assertEqual(
        InputResponses,
        maps:get(<<"inputResponses">>, Params)
    ).

tools_call_request_with_request_state_test() ->
    RequestState = <<"opaque-state">>,

    Request = erlmcp_protocol:tools_call_request(#{
        id => 6,
        name => <<"long_running_task">>,
        request_state => RequestState
    }),

    Params = maps:get(<<"params">>, Request),

    ?assertEqual(
        RequestState,
        maps:get(<<"requestState">>, Params)
    ).

tools_call_request_with_all_options_test() ->
    Arguments = #{<<"path">> => <<"/tmp/file.txt">>},
    InputResponses = [#{<<"id">> => <<"approval">>, <<"value">> => true}],
    RequestState = <<"state-123">>,

    Request = erlmcp_protocol:tools_call_request(#{
        id => 7,
        name => <<"delete_file">>,
        arguments => Arguments,
        input_responses => InputResponses,
        request_state => RequestState
    }),

    Params = maps:get(<<"params">>, Request),

    ?assertEqual(<<"delete_file">>, maps:get(<<"name">>, Params)),
    ?assertEqual(Arguments, maps:get(<<"arguments">>, Params)),
    ?assertEqual(InputResponses, maps:get(<<"inputResponses">>, Params)),
    ?assertEqual(RequestState, maps:get(<<"requestState">>, Params)).

%% ------------------------------------------------------------------
%% Server results
%% ------------------------------------------------------------------

tools_list_result_minimal_test() ->
    Tools = [
        #{
            <<"name">> => <<"get_time">>,
            <<"description">> => <<"Get current time">>,
            <<"inputSchema">> => #{<<"type">> => <<"object">>}
        }
    ],

    Result = erlmcp_protocol:tools_list_result(#{
        tools => Tools
    }),

    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(Tools, maps:get(<<"tools">>, Result)),
    ?assertEqual(0, maps:get(<<"ttlMs">>, Result)),
    ?assertEqual(<<"private">>, maps:get(<<"cacheScope">>, Result)),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(
            <<"io.modelcontextprotocol/serverInfo">>,
            maps:get(<<"_meta">>, Result)
        )
    ).

tools_list_result_with_options_test() ->
    Tools = [],
    Cursor = <<"next-page">>,

    Result = erlmcp_protocol:tools_list_result(#{
        tools => Tools,
        ttl_ms => 5000,
        cache_scope => <<"public">>,
        next_cursor => Cursor
    }),

    ?assertEqual(5000, maps:get(<<"ttlMs">>, Result)),
    ?assertEqual(<<"public">>, maps:get(<<"cacheScope">>, Result)),
    ?assertEqual(Cursor, maps:get(<<"nextCursor">>, Result)).

tools_list_result_without_next_cursor_test() ->
    Result = erlmcp_protocol:tools_list_result(#{
        tools => []
    }),

    ?assertNot(maps:is_key(<<"nextCursor">>, Result)).

tools_call_result_minimal_test() ->
    Content = [
        #{
            <<"type">> => <<"text">>,
            <<"text">> => <<"Operation completed">>
        }
    ],

    Result = erlmcp_protocol:tools_call_result(#{
        content => Content
    }),

    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(Content, maps:get(<<"content">>, Result)),
    ?assertEqual(false, maps:get(<<"isError">>, Result)),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(
            <<"io.modelcontextprotocol/serverInfo">>,
            maps:get(<<"_meta">>, Result)
        )
    ).

tools_call_result_error_test() ->
    Result = erlmcp_protocol:tools_call_result(#{
        content => [
            #{
                <<"type">> => <<"text">>,
                <<"text">> => <<"Tool execution failed">>
            }
        ],
        is_error => true
    }),

    ?assertEqual(true, maps:get(<<"isError">>, Result)).

tools_call_result_with_structured_content_test() ->
    StructuredContent = #{
        <<"status">> => <<"ok">>,
        <<"count">> => 3
    },

    Result = erlmcp_protocol:tools_call_result(#{
        content => [],
        structured_content => StructuredContent
    }),

    ?assertEqual(
        StructuredContent,
        maps:get(<<"structuredContent">>, Result)
    ).

tools_call_result_with_custom_meta_test() ->
    CustomMeta = #{
        <<"requestId">> => <<"abc-123">>
    },

    Result = erlmcp_protocol:tools_call_result(#{
        content => [],
        meta => CustomMeta
    }),

    Meta = maps:get(<<"_meta">>, Result),

    ?assertEqual(
        <<"abc-123">>,
        maps:get(<<"requestId">>, Meta)
    ),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(<<"io.modelcontextprotocol/serverInfo">>, Meta)
    ).

tools_call_result_server_info_cannot_be_overridden_test() ->
    CustomMeta = #{
        <<"io.modelcontextprotocol/serverInfo">> => #{
            <<"name">> => <<"another-server">>,
            <<"version">> => <<"9.9.9">>
        }
    },

    Result = erlmcp_protocol:tools_call_result(#{
        content => [],
        meta => CustomMeta
    }),

    Meta = maps:get(<<"_meta">>, Result),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(<<"io.modelcontextprotocol/serverInfo">>, Meta)
    ).

%% ------------------------------------------------------------------
%% Multi-round-trip results
%% ------------------------------------------------------------------

input_required_result_with_requests_test() ->
    InputRequests = [
        #{
            <<"id">> => <<"confirmation">>,
            <<"message">> => <<"Confirm this operation">>
        }
    ],

    Result = erlmcp_protocol:input_required_result(#{
        input_requests => InputRequests
    }),

    ?assertEqual(
        <<"input_required">>,
        maps:get(<<"resultType">>, Result)
    ),

    ?assertEqual(
        InputRequests,
        maps:get(<<"inputRequests">>, Result)
    ).

input_required_result_with_state_test() ->
    RequestState = <<"opaque-state">>,

    Result = erlmcp_protocol:input_required_result(#{
        request_state => RequestState
    }),

    ?assertEqual(
        <<"input_required">>,
        maps:get(<<"resultType">>, Result)
    ),

    ?assertEqual(
        RequestState,
        maps:get(<<"requestState">>, Result)
    ).

input_required_result_with_both_test() ->
    InputRequests = [#{<<"id">> => <<"approval">>}],
    RequestState = <<"state-456">>,

    Result = erlmcp_protocol:input_required_result(#{
        input_requests => InputRequests,
        request_state => RequestState
    }),

    ?assertEqual(
        InputRequests,
        maps:get(<<"inputRequests">>, Result)
    ),

    ?assertEqual(
        RequestState,
        maps:get(<<"requestState">>, Result)
    ).

input_required_result_without_required_fields_test() ->
    ?assertError(
        missing_input_requests_and_request_state,
        erlmcp_protocol:input_required_result(#{})
    ).

input_required_result_includes_server_info_test() ->
    Result = erlmcp_protocol:input_required_result(#{
        request_state => <<"state">>
    }),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(
            <<"io.modelcontextprotocol/serverInfo">>,
            maps:get(<<"_meta">>, Result)
        )
    ).

%% ------------------------------------------------------------------
%% Server discovery
%% ------------------------------------------------------------------

server_discover_request_test() ->
    Request = erlmcp_protocol:server_discover_request(10),

    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 10,
            <<"method">> => <<"server/discover">>,
            <<"params">> => #{
                <<"_meta">> => erlmcp_protocol:request_meta()
            }
        },
        Request
    ).

server_discover_result_minimal_test() ->
    Capabilities = #{
        <<"tools">> => #{}
    },

    Result = erlmcp_protocol:server_discover_result(#{
        capabilities => Capabilities
    }),

    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(
        [erlmcp_protocol:protocol_version()],
        maps:get(<<"supportedVersions">>, Result)
    ),
    ?assertEqual(Capabilities, maps:get(<<"capabilities">>, Result)),
    ?assertEqual(0, maps:get(<<"ttlMs">>, Result)),
    ?assertEqual(<<"private">>, maps:get(<<"cacheScope">>, Result)),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(
            <<"io.modelcontextprotocol/serverInfo">>,
            maps:get(<<"_meta">>, Result)
        )
    ).

server_discover_result_with_options_test() ->
    Capabilities = #{<<"tools">> => #{}},
    Versions = [<<"2026-07-28">>, <<"2026-01-26">>],
    Instructions = <<"Use tools for local operations.">>,

    Result = erlmcp_protocol:server_discover_result(#{
        capabilities => Capabilities,
        supported_versions => Versions,
        ttl_ms => 10000,
        cache_scope => <<"public">>,
        instructions => Instructions
    }),

    ?assertEqual(Versions, maps:get(<<"supportedVersions">>, Result)),
    ?assertEqual(10000, maps:get(<<"ttlMs">>, Result)),
    ?assertEqual(<<"public">>, maps:get(<<"cacheScope">>, Result)),
    ?assertEqual(Instructions, maps:get(<<"instructions">>, Result)).

server_discover_result_custom_meta_test() ->
    CustomMeta = #{
        <<"traceId">> => <<"trace-123">>
    },

    Result = erlmcp_protocol:server_discover_result(#{
        capabilities => #{},
        meta => CustomMeta
    }),

    Meta = maps:get(<<"_meta">>, Result),

    ?assertEqual(<<"trace-123">>, maps:get(<<"traceId">>, Meta)),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(<<"io.modelcontextprotocol/serverInfo">>, Meta)
    ).

%% ------------------------------------------------------------------
%% Subscription notifications and results
%% ------------------------------------------------------------------

tools_list_changed_notification_test() ->
    SubscriptionId = <<"subscription-123">>,

    Notification = erlmcp_protocol:tools_list_changed_notification(#{
        subscription_id => SubscriptionId
    }),

    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/tools/list_changed">>,
            <<"params">> => #{
                <<"_meta">> => #{
                    <<"io.modelcontextprotocol/subscriptionId">> =>
                        SubscriptionId
                }
            }
        },
        Notification
    ).

subscriptions_listen_request_test() ->
    Notifications = #{
        <<"toolsListChanged">> => true
    },

    Request = erlmcp_protocol:subscriptions_listen_request(#{
        id => 20,
        notifications => Notifications
    }),

    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 20,
            <<"method">> => <<"subscriptions/listen">>,
            <<"params">> => #{
                <<"notifications">> => Notifications,
                <<"_meta">> => erlmcp_protocol:request_meta()
            }
        },
        Request
    ).

subscriptions_acknowledged_notification_test() ->
    SubscriptionId = <<"subscription-456">>,
    Notifications = #{
        <<"toolsListChanged">> => true
    },

    Notification =
        erlmcp_protocol:subscriptions_acknowledged_notification(#{
            subscription_id => SubscriptionId,
            notifications => Notifications
        }),

    ?assertEqual(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/subscriptions/acknowledged">>,
            <<"params">> => #{
                <<"_meta">> => #{
                    <<"io.modelcontextprotocol/subscriptionId">> =>
                        SubscriptionId
                },
                <<"notifications">> => Notifications
            }
        },
        Notification
    ).

subscriptions_listen_result_test() ->
    SubscriptionId = <<"subscription-789">>,

    Result = erlmcp_protocol:subscriptions_listen_result(SubscriptionId),

    ?assertEqual(
        <<"complete">>,
        maps:get(<<"resultType">>, Result)
    ),

    Meta = maps:get(<<"_meta">>, Result),

    ?assertEqual(
        SubscriptionId,
        maps:get(<<"io.modelcontextprotocol/subscriptionId">>, Meta)
    ),

    ?assertEqual(
        erlmcp_protocol:server_info(),
        maps:get(<<"io.modelcontextprotocol/serverInfo">>, Meta)
    ).
