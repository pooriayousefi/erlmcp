%%--------------------------------------------------------------------
%% @doc
%% Streamable HTTP transport for MCP clients (protocol 2026-07-28).
%%
%% Responsibilities:
%%   - POST every JSON-RPC message to a single MCP endpoint.
%%   - Attach the required MCP headers (MCP-Protocol-Version,
%%     Mcp-Method, Mcp-Name when applicable).
%%   - Accept both application/json and text/event-stream responses.
%%   - Decode a plain JSON body or the final event of an SSE stream
%%     and forward the resulting JSON-RPC message to the bound
%%     client connection.
%%
%% The transport is deliberately stateless with respect to the
%% protocol. Each request is an independent HTTP POST.
%%
%% This module uses the OTP inets HTTP client (httpc). No external
%% dependencies are required.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_transport_http).

-behaviour(gen_server).

-export([
    start_link/1,
    start_link/2,
    stop/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_TIMEOUT, 30000).
-define(USER_AGENT, <<"erlmcp/0.1.0">>).

-record(state, {
    url :: binary(),
    extra_headers = [] :: [{binary(), binary()}],
    http_options = [] :: proplists:proplist(),
    connection :: pid() | undefined,
    request_timeout = ?DEFAULT_TIMEOUT :: timeout()
}).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Start an HTTP transport bound to the given MCP endpoint URL.
start_link(Url) ->
    start_link(Url, #{}).

%% @doc Start an HTTP transport with configuration options.
%%
%% Options:
%%   headers         - additional HTTP headers [{binary(), binary()}]
%%   http_options    - options passed to httpc:request/4
%%   request_timeout - default request timeout in milliseconds
start_link(Url, Options) when is_map(Options) ->
    NormalizedUrl = normalize_url(Url),
    case is_binary(NormalizedUrl) andalso byte_size(NormalizedUrl) > 0 of
        true ->
            gen_server:start_link(?MODULE, {NormalizedUrl, Options}, []);
        false ->
            {error, invalid_url}
    end;
start_link(_Url, _Options) ->
    {error, invalid_options}.

stop(Transport) ->
    gen_server:stop(Transport).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Url, Options}) ->
    %% Ensure inets is available for httpc.
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),

    ExtraHeaders = maps:get(headers, Options, []),
    HttpOptions = maps:get(http_options, Options, []),
    Timeout = maps:get(request_timeout, Options, ?DEFAULT_TIMEOUT),

    {ok, #state{
        url = Url,
        extra_headers = normalize_headers(ExtraHeaders),
        http_options = HttpOptions,
        request_timeout = Timeout
    }}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_operation}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% Outgoing request from the client connection.
handle_info(
    {erlmcp_client_connection, Connection, {send, Request}},
    State
) when is_pid(Connection), is_map(Request) ->
    handle_outgoing(Connection, Request, State);

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Outgoing request handling
%%====================================================================

handle_outgoing(Connection, Request, State) ->
    State1 = bind_connection(Connection, State),
    case encode_and_post(Request, State1) of
        {ok, Response} ->
            notify(Connection, {data, Response}, State1),
            {noreply, State1};
        {error, Reason} ->
            notify(Connection, {error, Reason}, State1),
            {noreply, State1}
    end.

bind_connection(Connection, #state{connection = undefined} = State) ->
    State#state{connection = Connection};
bind_connection(Connection, #state{connection = Connection} = State) ->
    State;
bind_connection(_Connection, State) ->
    %% Already bound to a different connection; keep the existing one.
    State.

%%====================================================================
%% HTTP POST + response decoding
%%====================================================================

encode_and_post(Request, State) ->
    case erlmcp_jsonrpc:validate(Request) of
        {ok, _Type} ->
            do_post(Request, State);
        {error, ValidationReason} ->
            {error, {invalid_jsonrpc_message, ValidationReason}}
    end.

do_post(Request, #state{url = Url} = State) ->
    Method = maps:get(<<"method">>, Request, undefined),
    Body = encode_body(Request),
    Headers = build_headers(Request, Method, State),

    HttpOpts = [
        {timeout, State#state.request_timeout},
        {connect_timeout, 10000}
        | State#state.http_options
    ],

    RequestOpts = [
        {body_format, binary}
    ],

    case httpc:request(
        post,
        {binary_to_list(Url), Headers, "application/json", Body},
        HttpOpts,
        RequestOpts
    ) of
        {ok, {{_HttpVersion, StatusCode, _ReasonPhrase}, RespHeaders, RespBody}} ->
            handle_http_response(StatusCode, RespHeaders, RespBody);
        {error, Reason} ->
            {error, {http_request_failed, Reason}}
    end.

encode_body(Request) ->
    iolist_to_binary(json:encode(Request)).

build_headers(Request, Method, State) ->
    ProtocolVersion = erlmcp_protocol:protocol_version(),

    Base = [
        {"Accept", "application/json, text/event-stream"},
        {"Content-Type", "application/json"},
        {"MCP-Protocol-Version", binary_to_list(ProtocolVersion)},
        {"User-Agent", binary_to_list(?USER_AGENT)}
    ],

    MethodHeaders =
        case is_binary(Method) of
            true ->
                [{"Mcp-Method", binary_to_list(Method)} | name_header(Request, Method)];
            false ->
                []
        end,

    Extra = [
        {binary_to_list(K), binary_to_list(V)}
     || {K, V} <- State#state.extra_headers
    ],

    Base ++ MethodHeaders ++ Extra.

name_header(Request, <<"tools/call">>) ->
    case maps:get(<<"params">>, Request, #{}) of
        #{<<"name">> := Name} when is_binary(Name) ->
            [{"Mcp-Name", binary_to_list(Name)}];
        _ ->
            []
    end;
name_header(_Request, _Method) ->
    [].

%%====================================================================
%% Response handling (JSON or SSE)
%%====================================================================

handle_http_response(StatusCode, Headers, Body)
        when StatusCode >= 200, StatusCode < 300 ->
    ContentType = content_type(Headers),
    case is_sse(ContentType) of
        true ->
            decode_sse(Body);
        false ->
            decode_json(Body)
    end;
handle_http_response(StatusCode, _Headers, Body) ->
    {error, {http_error, StatusCode, Body}}.

content_type(Headers) ->
    case lists:keyfind("content-type", 1, normalize_header_names(Headers)) of
        {_, Value} -> string:lowercase(Value);
        false -> ""
    end.

normalize_header_names(Headers) ->
    [{string:lowercase(K), V} || {K, V} <- Headers].

is_sse(ContentType) ->
    string:find(ContentType, "text/event-stream") =/= nomatch.

decode_json(Body) when is_binary(Body) ->
    try
        case json:decode(Body) of
            Message when is_map(Message) ->
                case erlmcp_jsonrpc:validate(Message) of
                    {ok, _} ->
                        {ok, Message};
                    {error, Reason} ->
                        {error, {invalid_jsonrpc_response, Reason}}
                end;
            _ ->
                {error, response_must_be_object}
        end
    catch
        Class:CatchReason ->
            {error, {json_decode_failed, Class, CatchReason}}
    end;
decode_json(Body) when is_list(Body) ->
    decode_json(list_to_binary(Body));
decode_json(_) ->
    {error, invalid_response_body}.

%% Extract the last data: payload from a simple SSE stream.
%% For the common case of a single final JSON-RPC response this is
%% sufficient. More sophisticated multi-event handling can be added
%% later if progress notifications are required.
decode_sse(Body) when is_binary(Body) ->
    Lines = binary:split(Body, [<<"\r\n">>, <<"\n">>], [global]),
    case extract_last_data(Lines) of
        {ok, Data} ->
            decode_json(Data);
        {error, _} = Error ->
            Error
    end;
decode_sse(Body) when is_list(Body) ->
    decode_sse(list_to_binary(Body));
decode_sse(_) ->
    {error, invalid_sse_body}.

extract_last_data(Lines) ->
    extract_last_data(Lines, undefined).

extract_last_data([], undefined) ->
    {error, empty_sse_stream};
extract_last_data([], Data) ->
    {ok, Data};
extract_last_data([Line | Rest], Acc) ->
    case Line of
        <<"data:", RestOfLine/binary>> ->
            Data = string:trim(RestOfLine),
            extract_last_data(Rest, Data);
        _ ->
            extract_last_data(Rest, Acc)
    end.

%%====================================================================
%% Helpers
%%====================================================================

notify(_Connection, _Event, #state{connection = undefined}) ->
    ok;
notify(Connection, Event, _State) ->
    Connection ! {erlmcp_transport, self(), Event},
    ok.

normalize_url(Url) when is_binary(Url) ->
    Url;
normalize_url(Url) when is_list(Url) ->
    list_to_binary(Url);
normalize_url(_) ->
    <<>>.

normalize_headers(Headers) when is_list(Headers) ->
    [
        {to_bin(K), to_bin(V)}
     || {K, V} <- Headers
    ];
normalize_headers(_) ->
    [].

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
