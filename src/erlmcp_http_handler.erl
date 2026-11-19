%%--------------------------------------------------------------------
%% @doc
%% Minimal Streamable HTTP request handler for MCP servers
%% (protocol version 2026-07-28).
%%
%% This module is deliberately framework-agnostic. It accepts a
%% decoded request body (map) together with the raw HTTP headers and
%% returns a response description that a Cowboy / Elli / custom
%% HTTP server can turn into a real HTTP reply.
%%
%% Expected usage (Cowboy example):
%%
%%   handle(Req, State) ->
%%       {ok, Body, Req1} = cowboy_req:read_body(Req),
%%       Headers = cowboy_req:headers(Req),
%%       case erlmcp_http_handler:handle(Body, Headers) of
%%           {ok, Status, RespHeaders, RespBody} ->
%%               cowboy_req:reply(Status, RespHeaders, RespBody, Req1);
%%           ...
%%       end.
%%
%% The handler:
%%   - Validates required MCP headers (MCP-Protocol-Version, Mcp-Method).
%%   - Decodes the JSON-RPC body.
%%   - Dispatches through erlmcp_server:handle_message/1.
%%   - Returns either a JSON response or an error status.
%%
%% SSE streaming of intermediate notifications is not implemented in
%% this minimal handler; every reply is a single application/json body.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_http_handler).

-export([
    handle/2,
    handle/3
]).

-define(PROTOCOL_VERSION, <<"2026-07-28">>).

-type header_map() :: #{binary() => binary()}.
-type response() ::
    {ok, pos_integer(), [{binary(), binary()}], binary()} |
    {error, pos_integer(), binary()}.

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

%% @doc Handle a raw request body and a map of headers.
-spec handle(binary() | map(), header_map()) -> response().
handle(Body, Headers) when is_map(Headers) ->
    handle(Body, Headers, #{}).

%% @doc Handle a request with optional extra configuration.
%%
%% Options (currently unused, reserved for future auth / origin checks):
%%   allowed_origins - list of binary() origins that are accepted
-spec handle(binary() | map(), header_map(), map()) -> response().
handle(Body, Headers, _Options) when is_map(Headers) ->
    case validate_headers(Headers) of
        ok ->
            case decode_body(Body) of
                {ok, Message} ->
                    dispatch(Message);
                {error, Reason} ->
                    json_error(400, Reason)
            end;
        {error, Reason} ->
            json_error(400, Reason)
    end;
handle(_Body, _Headers, _Options) ->
    json_error(400, invalid_headers).

%%--------------------------------------------------------------------
%% Header validation
%%--------------------------------------------------------------------

validate_headers(Headers) ->
    Version = header(Headers, <<"mcp-protocol-version">>,
                     <<"MCP-Protocol-Version">>),
    Method  = header(Headers, <<"mcp-method">>,
                     <<"Mcp-Method">>),

    case Version of
        undefined ->
            {error, missing_protocol_version_header};
        V when V =:= ?PROTOCOL_VERSION ->
            case Method of
                undefined ->
                    {error, missing_method_header};
                _ ->
                    ok
            end;
        Other ->
            {error, {unsupported_protocol_version, Other}}
    end.

header(Headers, Key1, Key2) ->
    case maps:find(Key1, Headers) of
        {ok, Value} -> Value;
        error ->
            case maps:find(Key2, Headers) of
                {ok, Value} -> Value;
                error -> undefined
            end
    end.

%%--------------------------------------------------------------------
%% Body decoding
%%--------------------------------------------------------------------

decode_body(Body) when is_map(Body) ->
    {ok, Body};
decode_body(Body) when is_binary(Body) ->
    try
        case json:decode(Body) of
            Message when is_map(Message) ->
                {ok, Message};
            _ ->
                {error, body_must_be_json_object}
        end
    catch
        Class:Reason ->
            {error, {json_decode_failed, Class, Reason}}
    end;
decode_body(_) ->
    {error, invalid_body}.

%%--------------------------------------------------------------------
%% Dispatch into the protocol layer
%%--------------------------------------------------------------------

dispatch(Message) ->
    case erlmcp_server:handle_message(Message) of
        {ok, Response} when is_map(Response) ->
            encode_success(Response);
        no_response ->
            %% Notifications produce no body.
            {ok, 204, [], <<>>};
        {error, Reason} ->
            json_error(500, Reason)
    end.

encode_success(Response) ->
    try
        Body = iolist_to_binary(json:encode(Response)),
        Headers = [
            {<<"content-type">>, <<"application/json">>},
            {<<"cache-control">>, <<"no-store">>}
        ],
        {ok, 200, Headers, Body}
    catch
        Class:Reason ->
            json_error(500, {encode_failed, Class, Reason})
    end.

json_error(Status, Reason) ->
    ErrorBody = iolist_to_binary(json:encode(#{
        <<"error">> => #{
            <<"code">> => Status,
            <<"message">> => reason_to_binary(Reason)
        }
    })),
    {error, Status, ErrorBody}.

reason_to_binary(Reason) when is_binary(Reason) ->
    Reason;
reason_to_binary(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
reason_to_binary(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).
