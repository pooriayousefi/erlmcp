
%%--------------------------------------------------------------------
%% @doc
%% Stateless MCP client API for protocol version 2026-07-28.
%%
%% Responsibilities:
%%   - Discover remote server versions and capabilities.
%%   - Request and validate remote tool catalogues.
%%   - Invoke remote tools, including multi-round-trip requests.
%%   - Validate JSON-RPC response IDs and MCP result structures.
%%   - Translate remote errors and connection failures into explicit
%%     client return values.
%%
%% Architectural role:
%%   This module is the protocol-facing client facade. It constructs
%%   requests through erlmcp_protocol and delegates delivery to a
%%   gen_server connection process. It does not implement transports.
%%
%% Connection contract:
%%   The connection process accepts {request, JsonRpcRequest} through
%%   gen_server:call/3 and replies with a decoded JSON-RPC response.
%%--------------------------------------------------------------------
-module(erlmcp_client).

-export([
    discover/1,
    discover/2,
    list_tools/1,
    list_tools/2,
    call_tool/3,
    call_tool/4,
    validate_response/2
]).

-define(DEFAULT_TIMEOUT, 30000).

-type connection() :: pid() | atom().
-type request_id() :: integer().
-type client_result() :: {ok, map()} | {error, term()}.

%%--------------------------------------------------------------------
%% Server discovery
%%--------------------------------------------------------------------

-spec discover(connection()) -> client_result().
discover(Connection) ->
    discover(Connection, ?DEFAULT_TIMEOUT).

-spec discover(connection(), timeout()) -> client_result().
discover(Connection, Timeout) ->
    Id = new_request_id(),
    Request = erlmcp_protocol:server_discover_request(Id),

    case send_request(Connection, Request, Timeout) of
        {ok, Result} ->
            validate_discovery_result(Result);
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Tool discovery
%%--------------------------------------------------------------------

-spec list_tools(connection()) -> client_result().
list_tools(Connection) ->
    list_tools(Connection, #{}).

-spec list_tools(connection(), map()) -> client_result().
list_tools(Connection, Options) when is_map(Options) ->
    Id = new_request_id(),

    RequestOptions = #{id => Id},

    RequestOptionsWithCursor =
        case maps:find(cursor, Options) of
            {ok, Cursor} ->
                RequestOptions#{cursor => Cursor};
            error ->
                RequestOptions
        end,

    Request = erlmcp_protocol:tools_list_request(
        RequestOptionsWithCursor
    ),

    Timeout = maps:get(timeout, Options, ?DEFAULT_TIMEOUT),

    case send_request(Connection, Request, Timeout) of
        {ok, Result} ->
            validate_tools_list_result(Result);
        Error ->
            Error
    end;

list_tools(_Connection, _Options) ->
    {error, invalid_options}.

%%--------------------------------------------------------------------
%% Tool invocation
%%--------------------------------------------------------------------

-spec call_tool(connection(), binary(), map()) -> client_result().
call_tool(Connection, Name, Arguments) ->
    call_tool(Connection, Name, Arguments, #{}).

-spec call_tool(connection(), binary(), map(), map()) -> client_result().
call_tool(Connection, Name, Arguments, Options)
        when is_binary(Name), byte_size(Name) > 0,
             is_map(Arguments), is_map(Options) ->
    Timeout = maps:get(timeout, Options, ?DEFAULT_TIMEOUT),
    MaxRounds = maps:get(max_input_rounds, Options, 5),
    InputHandler = maps:get(input_handler, Options, undefined),

    case valid_timeout(Timeout) andalso
         is_integer(MaxRounds) andalso MaxRounds > 0 andalso
         valid_input_handler(InputHandler) of
        false ->
            {error, invalid_options};
        true ->
            Deadline = make_deadline(Timeout),
            InitialFields = add_optional_call_fields(#{}, Options),
            call_tool_round(
                Connection,
                Name,
                Arguments,
                Options,
                InitialFields,
                Deadline,
                MaxRounds,
                0
            )
    end;

call_tool(_Connection, _Name, _Arguments, _Options) ->
    {error, invalid_arguments}.

%%--------------------------------------------------------------------
%% Multi-round-trip tool invocation
%%--------------------------------------------------------------------

call_tool_round(
    Connection,
    Name,
    Arguments,
    Options,
    OptionalFields,
    Deadline,
    MaxRounds,
    Round
) ->
    case remaining_timeout(Deadline) of
        timeout ->
            {error, timeout};
        Timeout ->
            RequestOptions = maps:merge(
                #{
                    id => new_request_id(),
                    name => Name,
                    arguments => Arguments
                },
                OptionalFields
            ),
            Request = erlmcp_protocol:tools_call_request(RequestOptions),
            case send_request(Connection, Request, Timeout) of
                {ok, Result} ->
                    case validate_tool_call_result(Result) of
                        {ok, #{<<"resultType">> := <<"input_required">>}}
                                when Round =:= 0 ->
                            maybe_resolve_input(
                                Connection, Name, Arguments, Options,
                                OptionalFields, Result, Deadline,
                                MaxRounds, Round
                            );
                        {ok, #{<<"resultType">> := <<"input_required">>}} ->
                            maybe_resolve_input(
                                Connection, Name, Arguments, Options,
                                OptionalFields, Result, Deadline,
                                MaxRounds, Round
                            );
                        Other ->
                            Other
                    end;
                Error ->
                    Error
            end
    end.

maybe_resolve_input(
    Connection, Name, Arguments, Options, OptionalFields, Result,
    Deadline, MaxRounds, Round
) ->
    case maps:get(input_handler, Options, undefined) of
        undefined ->
            {ok, Result};
        _Handler when Round >= MaxRounds ->
            {error, max_input_rounds_exceeded};
        Handler ->
            InputRequests = maps:get(<<"inputRequests">>, Result, []),
            RequestState = maps:get(<<"requestState">>, Result, undefined),
            Context = #{
                tool_name => Name,
                arguments => Arguments,
                request_state => RequestState,
                round => Round + 1
            },
            case invoke_input_handler(Handler, InputRequests, Context) of
                {ok, InputResponses} ->
                    NextFields0 = OptionalFields#{
                        input_responses => InputResponses
                    },
                    NextFields = case RequestState of
                        undefined -> maps:remove(request_state, NextFields0);
                        _ -> NextFields0#{request_state => RequestState}
                    end,
                    call_tool_round(
                        Connection, Name, Arguments, Options, NextFields,
                        Deadline, MaxRounds, Round + 1
                    );
                {error, Reason} ->
                    {error, {input_handler_error, Reason}}
            end
    end.

invoke_input_handler(Handler, InputRequests, Context) ->
    try Handler(InputRequests, Context) of
        {ok, Responses} when is_list(Responses) ->
            {ok, Responses};
        {error, _Reason} = Error ->
            Error;
        Other ->
            {error, {invalid_input_handler_result, Other}}
    catch
        Class:Reason ->
            {error, {input_handler_failed, Class, Reason}}
    end.

valid_input_handler(undefined) ->
    true;
valid_input_handler(Handler) ->
    is_function(Handler, 2).

make_deadline(infinity) ->
    infinity;
make_deadline(Timeout) ->
    erlang:monotonic_time(millisecond) + Timeout.

remaining_timeout(infinity) ->
    infinity;
remaining_timeout(Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        true -> Remaining;
        false -> timeout
    end.

%%--------------------------------------------------------------------
%% Request/response exchange
%%--------------------------------------------------------------------

send_request(Connection, Request, Timeout) ->
    case valid_timeout(Timeout) of
        false ->
            {error, invalid_timeout};

        true ->
            case safe_connection_call(Connection, Request, Timeout) of
                {ok, Response} ->
                    validate_response(
                        maps:get(<<"id">>, Request),
                        Response
                    );

                {error, _Reason} = Error ->
                    Error;

                Other ->
                    {error, {invalid_connection_response, Other}}
            end
    end.

safe_connection_call(Connection, Request, Timeout) ->
    try gen_server:call(
        Connection,
        {request, Request},
        Timeout
    ) of
        Response when is_map(Response) ->
            {ok, Response};
        Other ->
            {error, {invalid_response_type, Other}}
    catch
        exit:{timeout, _} ->
            {error, timeout};
        exit:Reason ->
            {error, {connection_error, Reason}};
        Class:Reason ->
            {error, {connection_failure, Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% JSON-RPC response validation
%%--------------------------------------------------------------------

-spec validate_response(request_id(), term()) ->
    {ok, map()} | {error, term()}.

validate_response(_ExpectedId, Response) when not is_map(Response) ->
    {error, invalid_response};

validate_response(ExpectedId, Response) ->
    case erlmcp_jsonrpc:validate(Response) of
        {ok, response} ->
            ActualId = maps:get(<<"id">>, Response),
            case ActualId =:= ExpectedId of
                true ->
                    {ok, maps:get(<<"result">>, Response)};
                false ->
                    {error, {response_id_mismatch, ExpectedId, ActualId}}
            end;

        {ok, error_response} ->
            ActualId = maps:get(<<"id">>, Response),
            case ActualId =:= ExpectedId of
                true ->
                    {error, {remote_error, maps:get(<<"error">>, Response)}};
                false ->
                    {error, {response_id_mismatch, ExpectedId, ActualId}}
            end;

        {ok, _OtherType} ->
            {error, invalid_response_type};

        {error, Reason} ->
            {error, {invalid_jsonrpc_response, Reason}}
    end.

%%--------------------------------------------------------------------
%% Discovery result validation
%%--------------------------------------------------------------------

validate_discovery_result(Result) when not is_map(Result) ->
    {error, invalid_discovery_result};

validate_discovery_result(Result) ->
    Versions = maps:get(<<"supportedVersions">>, Result, undefined),
    Capabilities = maps:get(<<"capabilities">>, Result, undefined),

    case validate_common_result(Result) of
        ok ->
            case maps:get(<<"resultType">>, Result) =:= <<"complete">>
                 andalso is_binary_list(Versions)
                 andalso is_map(Capabilities) of
                true ->
                    case lists:member(
                        erlmcp_protocol:protocol_version(),
                        Versions
                    ) of
                        true -> {ok, Result};
                        false ->
                            {error, {unsupported_protocol_version, Versions}}
                    end;
                false ->
                    {error, invalid_discovery_result}
            end;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Tool-list result validation
%%--------------------------------------------------------------------

validate_tools_list_result(Result) when not is_map(Result) ->
    {error, invalid_tools_list_result};

validate_tools_list_result(Result) ->
    Tools = maps:get(<<"tools">>, Result, undefined),

    case validate_common_result(Result) of
        ok ->
            case maps:get(<<"resultType">>, Result) =:= <<"complete">>
                 andalso is_list(Tools) of
                true ->
                    case validate_tools(Tools) of
                        ok -> {ok, Result};
                        Error -> Error
                    end;
                false ->
                    {error, invalid_tools_list_result}
            end;
        Error ->
            Error
    end.

validate_tools([]) ->
    ok;

validate_tools([Tool | Rest]) when is_map(Tool) ->
    Name = maps:get(<<"name">>, Tool, undefined),
    InputSchema = maps:get(<<"inputSchema">>, Tool, undefined),

    case is_nonempty_binary(Name) andalso is_map(InputSchema) of
        true -> validate_tools(Rest);
        false -> {error, invalid_tool_definition}
    end;

validate_tools(_) ->
    {error, invalid_tool_definition}.

%%--------------------------------------------------------------------
%% Tool-call result validation
%%--------------------------------------------------------------------

validate_tool_call_result(Result) when not is_map(Result) ->
    {error, invalid_tool_call_result};

validate_tool_call_result(Result) ->
    case validate_common_result(Result) of
        ok ->
            case maps:get(<<"resultType">>, Result) of
                <<"complete">> ->
                    validate_complete_tool_result(Result);
                <<"input_required">> ->
                    validate_input_required_result(Result);
                _ ->
                    {error, invalid_tool_call_result_type}
            end;
        Error ->
            Error
    end.

validate_complete_tool_result(Result) ->
    Content = maps:get(<<"content">>, Result, undefined),
    IsError = maps:get(<<"isError">>, Result, undefined),

    case is_list(Content) andalso is_boolean(IsError) of
        true -> {ok, Result};
        false -> {error, invalid_tool_call_result}
    end.

validate_input_required_result(Result) ->
    HasRequests = maps:is_key(<<"inputRequests">>, Result),
    HasState = maps:is_key(<<"requestState">>, Result),

    case HasRequests orelse HasState of
        false ->
            {error, invalid_input_required_result};
        true ->
            case maps:find(<<"inputRequests">>, Result) of
                error ->
                    {ok, Result};
                {ok, Requests} when is_list(Requests) ->
                    {ok, Result};
                {ok, _} ->
                    {error, invalid_input_required_result}
            end
    end.

%%--------------------------------------------------------------------
%% Common result envelope and server identity validation
%%--------------------------------------------------------------------

validate_common_result(Result) ->
    ResultType = maps:get(<<"resultType">>, Result, undefined),
    Meta = maps:get(<<"_meta">>, Result, undefined),

    case is_binary(ResultType) andalso is_map(Meta) of
        true -> validate_server_info(Meta);
        false -> {error, invalid_mcp_result_envelope}
    end.

validate_server_info(Meta) ->
    case maps:get(
        <<"io.modelcontextprotocol/serverInfo">>,
        Meta,
        undefined
    ) of
        ServerInfo when is_map(ServerInfo) ->
            Name = maps:get(<<"name">>, ServerInfo, undefined),
            Version = maps:get(<<"version">>, ServerInfo, undefined),

            case is_nonempty_binary(Name) andalso
                 is_nonempty_binary(Version) of
                true -> ok;
                false -> {error, invalid_server_info}
            end;
        _ ->
            {error, missing_server_info}
    end.

%%--------------------------------------------------------------------
%% Request construction helpers
%%--------------------------------------------------------------------

add_optional_call_fields(Request, Options) ->
    WithInputResponses =
        case maps:find(input_responses, Options) of
            {ok, InputResponses} ->
                Request#{input_responses => InputResponses};
            error ->
                Request
        end,

    case maps:find(request_state, Options) of
        {ok, RequestState} ->
            WithInputResponses#{request_state => RequestState};
        error ->
            WithInputResponses
    end.

new_request_id() ->
    erlang:unique_integer([positive, monotonic]).

valid_timeout(infinity) ->
    true;
valid_timeout(Timeout) ->
    is_integer(Timeout) andalso Timeout > 0.

is_nonempty_binary(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0.

is_binary_list(List) when is_list(List) ->
    lists:all(fun is_binary/1, List);
is_binary_list(_) ->
    false.
