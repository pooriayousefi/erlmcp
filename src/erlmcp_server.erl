
%%--------------------------------------------------------------------
%% @doc
%% Stateless MCP server request dispatcher for protocol version
%% 2026-07-28.
%%
%% Responsibilities:
%%   - Validate incoming JSON-RPC messages.
%%   - Validate the MCP request metadata envelope on every request.
%%   - Dispatch server discovery, tool listing, and tool invocation.
%%   - Translate protocol and execution failures into JSON-RPC errors
%%     or MCP tool results, as appropriate.
%%   - Ignore notifications without producing JSON-RPC responses.
%%
%% Architectural role:
%%   This module is the protocol-facing boundary between MCP transports
%%   and the tool registry/executor. It does not own transport processes,
%%   sessions, or tool implementations. STDIO and HTTP transports pass
%%   decoded messages to handle_message/1 and serialize its responses.
%%
%% This implementation supports the stateless 2026-07-28 protocol only.
%%--------------------------------------------------------------------
-module(erlmcp_server).

-export([
    handle_message/1
]).

-define(PROTOCOL_VERSION, <<"2026-07-28">>).
-define(SERVER_NAME, <<"erlmcp">>).
-define(SERVER_VERSION, <<"0.1.0">>).

-define(JSONRPC_INVALID_REQUEST, -32600).
-define(JSONRPC_METHOD_NOT_FOUND, -32601).
-define(JSONRPC_INVALID_PARAMS, -32602).
-define(JSONRPC_INTERNAL_ERROR, -32603).

-define(MCP_UNSUPPORTED_PROTOCOL_VERSION, -32022).

-type response() :: map().
-type handle_result() :: {ok, response()} | no_response | {error, term()}.

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec handle_message(term()) -> handle_result().
handle_message(Message) ->
    case erlmcp_jsonrpc:validate(Message) of
        {ok, request} ->
            handle_request(Message);

        {ok, notification} ->
            handle_notification(Message);

        {ok, response} ->
            {error, unexpected_client_response};

        {ok, error_response} ->
            {error, unexpected_client_error_response};

        {error, Reason} ->
            {ok, jsonrpc_error(
                null,
                ?JSONRPC_INVALID_REQUEST,
                <<"Invalid Request">>,
                #{<<"reason">> => reason_to_binary(Reason)}
            )}
    end.

%%--------------------------------------------------------------------
%% Request handling
%%--------------------------------------------------------------------

handle_request(Message) ->
    Id = maps:get(<<"id">>, Message),
    Method = maps:get(<<"method">>, Message),
    Params = maps:get(<<"params">>, Message, #{}),

    case validate_request_metadata(Params) of
        ok ->
            dispatch_request(Id, Method, Params);

        {error, unsupported_protocol_version} ->
            {ok, jsonrpc_error(
                Id,
                ?MCP_UNSUPPORTED_PROTOCOL_VERSION,
                <<"Unsupported protocol version">>,
                #{
                    <<"supportedVersions">> => [?PROTOCOL_VERSION],
                    <<"receivedVersion">> =>
                        get_protocol_version(Params)
                }
            )};

        {error, Reason} ->
            {ok, jsonrpc_error(
                Id,
                ?JSONRPC_INVALID_PARAMS,
                <<"Invalid request metadata">>,
                #{<<"reason">> => reason_to_binary(Reason)}
            )}
    end.

dispatch_request(Id, <<"server/discover">>, _Params) ->
    handle_discover(Id);

dispatch_request(Id, <<"tools/list">>, _Params) ->
    handle_tools_list(Id);

dispatch_request(Id, <<"tools/call">>, Params) ->
    handle_tools_call(Id, Params);

dispatch_request(Id, _Method, _Params) ->
    {ok, jsonrpc_error(
        Id,
        ?JSONRPC_METHOD_NOT_FOUND,
        <<"Method not found">>,
        undefined
    )}.

%%--------------------------------------------------------------------
%% Notification handling
%%--------------------------------------------------------------------

handle_notification(Message) ->
    Params = maps:get(<<"params">>, Message, #{}),

    case validate_request_metadata(Params) of
        ok ->
            %% Notifications never receive JSON-RPC responses.
            %% Unknown notifications are deliberately ignored.
            no_response;

        {error, _Reason} ->
            %% A notification has no request ID to which an error
            %% response could be correlated.
            no_response
    end.

%%--------------------------------------------------------------------
%% Request metadata validation
%%--------------------------------------------------------------------

validate_request_metadata(Params) when not is_map(Params) ->
    {error, invalid_params};

validate_request_metadata(Params) ->
    case maps:get(<<"_meta">>, Params, undefined) of
        Meta when is_map(Meta) ->
            validate_metadata_fields(Meta);

        _ ->
            {error, missing_metadata}
    end.

validate_metadata_fields(Meta) ->
    Version = maps:get(
        <<"io.modelcontextprotocol/protocolVersion">>,
        Meta,
        undefined
    ),

    Capabilities = maps:get(
        <<"io.modelcontextprotocol/clientCapabilities">>,
        Meta,
        undefined
    ),

    ClientInfo = maps:get(
        <<"io.modelcontextprotocol/clientInfo">>,
        Meta,
        undefined
    ),

    case Version of
        ?PROTOCOL_VERSION ->
            validate_client_metadata(Capabilities, ClientInfo);

        _ ->
            {error, unsupported_protocol_version}
    end.

validate_client_metadata(Capabilities, _ClientInfo)
        when not is_map(Capabilities) ->
    {error, invalid_client_capabilities};

validate_client_metadata(_Capabilities, undefined) ->
    ok;

validate_client_metadata(_Capabilities, ClientInfo)
        when is_map(ClientInfo) ->
    Name = maps:get(<<"name">>, ClientInfo, undefined),
    Version = maps:get(<<"version">>, ClientInfo, undefined),

    case is_nonempty_binary(Name) andalso
         is_nonempty_binary(Version) of
        true ->
            ok;
        false ->
            {error, invalid_client_info}
    end;

validate_client_metadata(_Capabilities, _ClientInfo) ->
    {error, invalid_client_info}.

get_protocol_version(Params) when is_map(Params) ->
    case maps:get(<<"_meta">>, Params, undefined) of
        Meta when is_map(Meta) ->
            maps:get(
                <<"io.modelcontextprotocol/protocolVersion">>,
                Meta,
                null
            );
        _ ->
            null
    end;
get_protocol_version(_) ->
    null.

%%--------------------------------------------------------------------
%% Server discovery
%%--------------------------------------------------------------------

handle_discover(Id) ->
    Capabilities = #{
        <<"tools">> => #{}
    },

    DiscoverResult = erlmcp_protocol:server_discover_result(#{
        capabilities => Capabilities,
        supported_versions => [?PROTOCOL_VERSION],
        ttl_ms => 0,
        cache_scope => <<"private">>
    }),

    {ok, erlmcp_jsonrpc:response(Id, DiscoverResult)}.

%%--------------------------------------------------------------------
%% Tool listing
%%--------------------------------------------------------------------

handle_tools_list(Id) ->
    case safe_registry_call(fun erlmcp_tool_registry:list_tools/0) of
        {ok, Tools} when is_list(Tools) ->
            Result = erlmcp_protocol:tools_list_result(#{
                tools => Tools,
                ttl_ms => 0,
                cache_scope => <<"private">>
            }),

            {ok, erlmcp_jsonrpc:response(Id, Result)};

        {error, Reason} ->
            {ok, internal_error(Id, Reason)};

        Other ->
            {ok, internal_error(Id, {invalid_registry_response, Other})}
    end.

%%--------------------------------------------------------------------
%% Tool invocation
%%--------------------------------------------------------------------

handle_tools_call(Id, Params) ->
    case validate_tool_call_params(Params) of
        {ok, Name, Arguments, Context} ->
            execute_tool_call(Id, Name, Arguments, Context);

        {error, Reason} ->
            {ok, jsonrpc_error(
                Id,
                ?JSONRPC_INVALID_PARAMS,
                <<"Invalid tools/call parameters">>,
                #{<<"reason">> => reason_to_binary(Reason)}
            )}
    end.

validate_tool_call_params(Params) ->
    Name = maps:get(<<"name">>, Params, undefined),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    InputResponses = maps:get(<<"inputResponses">>, Params, undefined),
    RequestState = maps:get(<<"requestState">>, Params, undefined),

    case is_nonempty_binary(Name) of
        false ->
            {error, invalid_tool_name};
        true when not is_map(Arguments) ->
            {error, invalid_arguments};
        true when InputResponses =/= undefined,
                  not is_list(InputResponses) ->
            {error, invalid_input_responses};
        true when RequestState =/= undefined,
                  not is_binary(RequestState) ->
            {error, invalid_request_state};
        true ->
            Context0 = #{},
            Context1 = case InputResponses of
                undefined -> Context0;
                _ -> Context0#{input_responses => InputResponses}
            end,
            Context = case RequestState of
                undefined -> Context1;
                _ -> Context1#{request_state => RequestState}
            end,
            {ok, Name, Arguments, Context}
    end.

execute_tool_call(Id, Name, Arguments, Context) ->
    case safe_executor_call(
        fun() -> erlmcp_tool_executor:execute_tool(
            Name, Arguments, 30000, Context
        ) end
    ) of
        {ok, ToolResult} ->
            {ok, tool_success_response(Id, ToolResult)};

        {error, Reason} ->
            {ok, tool_failure_response(Id, Reason)};

        Other ->
            {ok, tool_failure_response(
                Id,
                {invalid_executor_response, Other}
            )}
    end.

tool_success_response(Id, ToolResult) ->
    case normalize_tool_result(ToolResult) of
        {ok, ResultFields} ->
            Result = erlmcp_protocol:tools_call_result(ResultFields),
            erlmcp_jsonrpc:response(Id, Result);

        {input_required, ResultFields} ->
            Result = erlmcp_protocol:input_required_result(ResultFields),
            erlmcp_jsonrpc:response(Id, Result);

        {error, Reason} ->
            tool_failure_response(Id, Reason)
    end.

normalize_tool_result(#{result_type := input_required} = Result) ->
    normalize_input_required_result(Result);

normalize_tool_result(#{<<"resultType">> := <<"input_required">>} = Result) ->
    normalize_input_required_result(Result);

normalize_tool_result(#{content := Content} = Result)
        when is_list(Content) ->
    {ok, #{
        content => Content,
        is_error => maps:get(is_error, Result, false),
        structured_content => maps:get(
            structured_content,
            Result,
            undefined
        ),
        meta => maps:get(meta, Result, #{})
    }};

normalize_tool_result(#{<<"content">> := Content} = Result)
        when is_list(Content) ->
    {ok, #{
        content => Content,
        is_error => maps:get(<<"isError">>, Result, false),
        structured_content => maps:get(
            <<"structuredContent">>,
            Result,
            undefined
        ),
        meta => maps:get(<<"_meta">>, Result, #{})
    }};

normalize_input_required_result(Result) ->
    InputRequests = maps:get(
        input_requests,
        Result,
        maps:get(<<"inputRequests">>, Result, undefined)
    ),
    RequestState = maps:get(
        request_state,
        Result,
        maps:get(<<"requestState">>, Result, undefined)
    ),
    case (InputRequests =:= undefined orelse is_list(InputRequests)) andalso
         (RequestState =:= undefined orelse is_binary(RequestState)) andalso
         (InputRequests =/= undefined orelse RequestState =/= undefined) of
        true ->
            Fields0 = #{},
            Fields1 = case InputRequests of
                undefined -> Fields0;
                _ -> Fields0#{input_requests => InputRequests}
            end,
            Fields2 = case RequestState of
                undefined -> Fields1;
                _ -> Fields1#{request_state => RequestState}
            end,
            {input_required, Fields2};
        false ->
            {error, invalid_input_required_result}
    end.

normalize_tool_result(Binary) when is_binary(Binary) ->
    {ok, #{
        content => [text_content(Binary)],
        is_error => false
    }};

normalize_tool_result(List) when is_list(List) ->
    {ok, #{
        content => List,
        is_error => false
    }};

normalize_tool_result(Other) ->
    {ok, #{
        content => [text_content(term_to_binary(Other))],
        is_error => false
    }}.

tool_failure_response(Id, Reason) ->
    Result = erlmcp_protocol:tools_call_result(#{
        content => [text_content(reason_to_binary(Reason))],
        is_error => true
    }),

    erlmcp_jsonrpc:response(Id, Result).

text_content(Text) ->
    #{
        <<"type">> => <<"text">>,
        <<"text">> => Text
    }.

%%--------------------------------------------------------------------
%% Error construction
%%--------------------------------------------------------------------

internal_error(Id, Reason) ->
    jsonrpc_error(
        Id,
        ?JSONRPC_INTERNAL_ERROR,
        <<"Internal error">>,
        #{<<"reason">> => reason_to_binary(Reason)}
    ).

jsonrpc_error(Id, Code, Message, Data) ->
    erlmcp_jsonrpc:error(Id, Code, Message, Data).

%%--------------------------------------------------------------------
%% Safe dependency calls
%%--------------------------------------------------------------------

safe_registry_call(Fun) ->
    try Fun() of
        Result ->
            Result
    catch
        Class:Reason ->
            {error, {registry_failure, Class, Reason}}
    end.

safe_executor_call(Fun) ->
    try Fun() of
        Result ->
            Result
    catch
        Class:Reason ->
            {error, {executor_failure, Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% General helpers
%%--------------------------------------------------------------------

is_nonempty_binary(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0.

reason_to_binary(Reason) when is_binary(Reason) ->
    Reason;
reason_to_binary(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
reason_to_binary(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).
