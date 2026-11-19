
-module(erlmcp_protocol).

-export([
    protocol_version/0,
    client_info/0,
    client_capabilities/0,
    request_meta/0,
    server_info/0,
    tools_list_request/1,
    tools_call_request/1,
    tools_list_result/1,
    tools_call_result/1,
    input_required_result/1,
    server_discover_request/1,
    server_discover_result/1,
    tools_list_changed_notification/1,
    subscriptions_listen_request/1,
    subscriptions_acknowledged_notification/1,
    subscriptions_listen_result/1
]).

-define(PROTOCOL_VERSION, <<"2026-07-28">>).

%% ------------------------------------------------------------------
%% Protocol identity and metadata
%% ------------------------------------------------------------------

protocol_version() ->
    ?PROTOCOL_VERSION.

%% Identity advertised by this implementation when acting as a client.
client_info() ->
    #{
        <<"name">> => <<"erlmcp">>,
        <<"version">> => <<"0.1.0">>
    }.

%% Capabilities supported by this client.
%% An empty map means no optional capabilities are currently advertised.
client_capabilities() ->
    #{}.

%% Metadata attached to client-initiated requests.
%% The protocol is stateless: each request carries the client's
%% protocol version, capabilities, and implementation identity.
request_meta() ->
    #{
        <<"io.modelcontextprotocol/protocolVersion">> => protocol_version(),
        <<"io.modelcontextprotocol/clientCapabilities">> =>
            client_capabilities(),
        <<"io.modelcontextprotocol/clientInfo">> => client_info()
    }.

%% Identity advertised when this implementation acts as a server.
server_info() ->
    #{
        <<"name">> => <<"erlmcp">>,
        <<"version">> => <<"0.1.0">>
    }.

%% ------------------------------------------------------------------
%% Client requests
%% ------------------------------------------------------------------

%% Request the server's tool catalogue.
%% An optional cursor requests the next page of results.
tools_list_request(#{id := Id} = Request) ->
    Params = case maps:find(cursor, Request) of
        {ok, Cursor} ->
            #{
                <<"cursor">> => Cursor,
                <<"_meta">> => request_meta()
            };
        error ->
            #{
                <<"_meta">> => request_meta()
            }
    end,

    erlmcp_jsonrpc:request(
        Id,
        <<"tools/list">>,
        Params
    ).

%% Invoke a remote tool.
%%
%% Required:
%%   id   - JSON-RPC request identifier
%%   name - tool name
%%
%% Optional:
%%   arguments       - tool input arguments
%%   input_responses - responses to requests from an earlier round
%%   request_state   - opaque state returned by the server
%%
%% Translate Erlang snake_case keys into MCP camelCase fields.
tools_call_request(#{
    id := Id,
    name := Name
} = Request) ->
    Arguments = maps:get(arguments, Request, #{}),

    OptionalParams = lists:foldl(
        fun({Source, Target}, Acc) ->
            case maps:find(Source, Request) of
                {ok, Value} ->
                    Acc#{Target => Value};
                error ->
                    Acc
            end
        end,
        #{},
        [
            {input_responses, <<"inputResponses">>},
            {request_state, <<"requestState">>}
        ]
    ),

    Params = maps:merge(
        #{
            <<"name">> => Name,
            <<"arguments">> => Arguments,
            <<"_meta">> => request_meta()
        },
        OptionalParams
    ),

    erlmcp_jsonrpc:request(
        Id,
        <<"tools/call">>,
        Params
    ).

%% ------------------------------------------------------------------
%% Server results
%% ------------------------------------------------------------------

%% Build a paginated tools/list result.
%%
%% Required input:
%%   tools
%%
%% Optional input:
%%   ttl_ms      - cache freshness hint in milliseconds
%%   cache_scope - "private" or "public"
%%   next_cursor - cursor for the next page
tools_list_result(#{tools := Tools} = Result) when is_list(Tools) ->
    Base = #{
        <<"resultType">> => <<"complete">>,
        <<"tools">> => Tools,
        <<"ttlMs">> => maps:get(ttl_ms, Result, 0),
        <<"cacheScope">> => maps:get(cache_scope, Result, <<"private">>)
    },

    WithCursor = case maps:find(next_cursor, Result) of
        {ok, Cursor} ->
            Base#{<<"nextCursor">> => Cursor};
        error ->
            Base
    end,

    WithCursor#{<<"_meta">> => result_meta(Result)}.

%% Build the result of a tool invocation.
%%
%% A tool execution failure is represented by isError = true.
%% It is still a successful JSON-RPC exchange. Errors concerning
%% the protocol or the tool request itself belong in JSON-RPC errors.
%%
%% structured_content is optional and may contain any JSON value.
tools_call_result(#{content := Content} = Result)
        when is_list(Content) ->
    Base = #{
        <<"resultType">> => <<"complete">>,
        <<"content">> => Content,
        <<"isError">> => maps:get(is_error, Result, false)
    },

    WithStructuredContent =
        case maps:find(structured_content, Result) of
            {ok, StructuredContent} ->
                Base#{<<"structuredContent">> => StructuredContent};
            error ->
                Base
        end,

    WithStructuredContent#{<<"_meta">> => result_meta(Result)}.

%% Build an input_required result for a multi-round-trip operation.
%%
%% At least one of input_requests or request_state must be provided.
%%
%% input_requests contains server-initiated requests that the client
%% must fulfill before retrying the original operation.
%%
%% request_state is an opaque string. The client must preserve it
%% and return it unchanged when retrying the original request.
input_required_result(Result) when is_map(Result) ->
    InputRequests = maps:find(input_requests, Result),
    RequestState = maps:find(request_state, Result),

    case {InputRequests, RequestState} of
        {error, error} ->
            erlang:error(missing_input_requests_and_request_state);
        _ ->
            Base = #{<<"resultType">> => <<"input_required">>},

            WithRequests =
                case InputRequests of
                    {ok, Requests} ->
                        Base#{<<"inputRequests">> => Requests};
                    error ->
                        Base
                end,

            WithState =
                case RequestState of
                    {ok, State} ->
                        WithRequests#{<<"requestState">> => State};
                    error ->
                        WithRequests
                end,

            WithState#{<<"_meta">> => result_meta(Result)}
    end.

%% ------------------------------------------------------------------
%% Server discovery
%% ------------------------------------------------------------------

%% Ask a server which protocol versions and capabilities it supports.
%% Discovery is optional for clients, but useful for version negotiation.
server_discover_request(Id) ->
    erlmcp_jsonrpc:request(
        Id,
        <<"server/discover">>,
        #{
            <<"_meta">> => request_meta()
        }
    ).

%% Build the response to server/discover.
%%
%% Required input:
%%   capabilities
%%
%% Optional input:
%%   supported_versions
%%   ttl_ms
%%   cache_scope
%%   instructions
server_discover_result(#{capabilities := Capabilities} = Result) ->
    Base = #{
        <<"resultType">> => <<"complete">>,
        <<"supportedVersions">> =>
            maps:get(supported_versions, Result, [protocol_version()]),
        <<"capabilities">> => Capabilities,
        <<"ttlMs">> => maps:get(ttl_ms, Result, 0),
        <<"cacheScope">> => maps:get(cache_scope, Result, <<"private">>)
    },

    WithInstructions =
        case maps:find(instructions, Result) of
            {ok, Instructions} ->
                Base#{<<"instructions">> => Instructions};
            error ->
                Base
        end,

    WithInstructions#{<<"_meta">> => result_meta(Result)}.

%% ------------------------------------------------------------------
%% Notifications
%% ------------------------------------------------------------------

%% Notify a subscribed client that the tool catalogue has changed.
%% The subscription ID identifies the stream carrying this notification.
tools_list_changed_notification(#{subscription_id := SubscriptionId}) ->
    erlmcp_jsonrpc:notification(
        <<"notifications/tools/list_changed">>,
        #{
            <<"_meta">> => #{
                <<"io.modelcontextprotocol/subscriptionId">> =>
                    SubscriptionId
            }
        }
    ).

%% ------------------------------------------------------------------
%% Subscriptions
%% ------------------------------------------------------------------

%% Open a subscription stream and declare the notification types
%% the client wants to receive.
subscriptions_listen_request(#{
    id := Id,
    notifications := Notifications
}) ->
    erlmcp_jsonrpc:request(
        Id,
        <<"subscriptions/listen">>,
        #{
            <<"notifications">> => Notifications,
            <<"_meta">> => request_meta()
        }
    ).

%% Acknowledge the subscription and report the notification filters
%% accepted by the server.
subscriptions_acknowledged_notification(#{
    subscription_id := SubscriptionId,
    notifications := Notifications
}) ->
    erlmcp_jsonrpc:notification(
        <<"notifications/subscriptions/acknowledged">>,
        #{
            <<"_meta">> => #{
                <<"io.modelcontextprotocol/subscriptionId">> =>
                    SubscriptionId
            },
            <<"notifications">> => Notifications
        }
    ).

%% Build the successful result for subscriptions/listen.
%% The subscription ID identifies the established stream.
subscriptions_listen_result(SubscriptionId) ->
    #{
        <<"resultType">> => <<"complete">>,
        <<"_meta">> => result_meta(#{
            meta => #{
                <<"io.modelcontextprotocol/subscriptionId">> => SubscriptionId
            }
        })
    }.

%% ------------------------------------------------------------------
%% Internal helpers
%% ------------------------------------------------------------------

%% Build response metadata consistently.
%%
%% Preserve application-provided metadata, but always use this
%% implementation's own serverInfo value for the reserved MCP key.
result_meta(Result) ->
    ExtraMeta = maps:get(meta, Result, #{}),

    maps:merge(
        ExtraMeta,
        #{
            <<"io.modelcontextprotocol/serverInfo">> => server_info()
        }
    ).
