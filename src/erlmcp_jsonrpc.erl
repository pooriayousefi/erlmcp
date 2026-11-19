-module(erlmcp_jsonrpc).

-moduledoc("""
JSON-RPC 2.0 message construction and structural validation.

JSON objects are represented as maps with binary keys.
JSON strings are represented as binaries.
""").

-export([
    request/3,
    notification/2,
    response/2,
    error/4,

    is_request/1,
    is_notification/1,
    is_response/1,
    is_error/1,

    validate/1
    ]).

-define(JSONRPC_VERSION, <<"2.0">>).

-type request_id() :: binary() | integer() | float().
-type json_object() :: map().
-type message_type() :: request | notification | response | error_response.

-export_type([request_id/0, json_object/0, message_type/0]).

%% ------------------------------------------------------------------
%% Message construction
%% ------------------------------------------------------------------

-spec request(request_id(), binary(), map() | list()) -> json_object().
request(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => ?JSONRPC_VERSION,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }.

-spec notification(binary(), map() | list()) -> json_object().
notification(Method, Params) ->
    #{
        <<"jsonrpc">> => ?JSONRPC_VERSION,
        <<"method">> => Method,
        <<"params">> => Params
    }.

-spec response(request_id(), term()) -> json_object().
response(Id, Result) ->
    #{
        <<"jsonrpc">> => ?JSONRPC_VERSION,
        <<"id">> => Id,
        <<"result">> => Result
    }.

-spec error(request_id() | null, integer(), binary(), term()) -> json_object().
error(Id, Code, Message, Data) ->
    ErrorObject = #{
        <<"code">> => Code,
        <<"message">> => Message
    },

    ErrorWithData =
        case Data of
            undefined ->
                ErrorObject;
            _ ->
                ErrorObject#{<<"data">> => Data}
        end,

    #{
        <<"jsonrpc">> => ?JSONRPC_VERSION,
        <<"id">> => Id,
        <<"error">> => ErrorWithData
    }.

%% ------------------------------------------------------------------
%% Message classification
%% ------------------------------------------------------------------

-spec is_request(term()) -> boolean().
is_request(Message) ->
    case validate(Message) of
        {ok, request} -> true;
        _ -> false
    end.

-spec is_notification(term()) -> boolean().
is_notification(Message) ->
    case validate(Message) of
        {ok, notification} -> true;
        _ -> false
    end.

-spec is_response(term()) -> boolean().
is_response(Message) ->
    case validate(Message) of
        {ok, response} -> true;
        _ -> false
    end.

-spec is_error(term()) -> boolean().
is_error(Message) ->
    case validate(Message) of
        {ok, error_response} -> true;
        _ -> false
    end.

%% ------------------------------------------------------------------
%% Structural validation
%% ------------------------------------------------------------------

-spec validate(term()) ->
    {ok, message_type()} |
    {error, term()}.

validate(Message) when not is_map(Message) ->
    {error, invalid_message};

validate(Message) ->
    case maps:get(<<"jsonrpc">>, Message, undefined) of
        ?JSONRPC_VERSION ->
            validate_message_fields(Message);
        _ ->
            {error, invalid_jsonrpc_version}
    end.

validate_message_fields(Message) ->
    HasId = maps:is_key(<<"id">>, Message),
    HasMethod = maps:is_key(<<"method">>, Message),
    HasResult = maps:is_key(<<"result">>, Message),
    HasError = maps:is_key(<<"error">>, Message),

    case {HasMethod, HasResult, HasError} of
        {true, false, false} ->
            validate_request_or_notification(Message, HasId);

        {false, true, false} ->
            validate_response_message(Message, HasId);

        {false, false, true} ->
            validate_error_message(Message, HasId);

        {false, false, false} ->
            {error, missing_message_field};

        _ ->
            {error, conflicting_message_fields}
    end.

validate_request_or_notification(Message, HasId) ->
    Method = maps:get(<<"method">>, Message),

    case is_nonempty_binary(Method) of
        false ->
            {error, invalid_method};

        true ->
            case validate_params(Message) of
                ok ->
                    case HasId of
                        true ->
                            validate_request_id(Message);
                        false ->
                            {ok, notification}
                    end;

                Error ->
                    Error
            end
    end.

validate_params(Message) ->
    case maps:find(<<"params">>, Message) of
        error ->
            ok;

        {ok, Params} when is_map(Params); is_list(Params) ->
            ok;

        {ok, _} ->
            {error, invalid_params}
    end.

validate_request_id(Message) ->
    Id = maps:get(<<"id">>, Message),

    case is_valid_id(Id) of
        true ->
            {ok, request};
        false ->
            {error, invalid_request_id}
    end.

validate_response_message(Message, HasId) ->
    case HasId of
        false ->
            {error, missing_response_id};

        true ->
            case is_valid_id(maps:get(<<"id">>, Message)) of
                true ->
                    {ok, response};
                false ->
                    {error, invalid_response_id}
            end
    end.

validate_error_message(Message, HasId) ->
    case HasId of
        false ->
            {error, missing_error_id};

        true ->
            Id = maps:get(<<"id">>, Message),
            ErrorObject = maps:get(<<"error">>, Message),

            case is_valid_error_id(Id) andalso
                 is_valid_error_object(ErrorObject) of
                true ->
                    {ok, error_response};
                false ->
                    {error, invalid_error_response}
            end
    end.

%% ------------------------------------------------------------------
%% Validation helpers
%% ------------------------------------------------------------------

is_valid_id(Id) when is_binary(Id) ->
    true;
is_valid_id(Id) when is_integer(Id) ->
    true;
is_valid_id(Id) when is_float(Id) ->
    true;
is_valid_id(_) ->
    false.

%% JSON-RPC permits null as the ID in an error response when
%% the request ID could not be determined.
is_valid_error_id(null) ->
    true;
is_valid_error_id(Id) ->
    is_valid_id(Id).

is_valid_error_object(ErrorObject) when is_map(ErrorObject) ->
    Code = maps:get(<<"code">>, ErrorObject, undefined),
    Message = maps:get(<<"message">>, ErrorObject, undefined),

    is_integer(Code) andalso is_binary(Message);

is_valid_error_object(_) ->
    false.

is_nonempty_binary(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0.