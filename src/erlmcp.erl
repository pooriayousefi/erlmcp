%%--------------------------------------------------------------------
%% @doc
%% Top-level facade for the erlmcp library.
%%
%% Provides convenient entry points for starting client connections
%% and for interacting with the tool registry from server code.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp).

-export([
    start/0,
    stop/0,
    protocol_version/0,

    %% Client helpers
    start_stdio_client/0,
    start_stdio_client/1,
    start_http_client/1,
    start_http_client/2,

    %% Server-side helpers
    register_tool/1,
    unregister_tool/1,
    list_tools/0
]).

%%--------------------------------------------------------------------
%% Application control
%%--------------------------------------------------------------------

%% @doc Start the erlmcp application (and its supervision tree).
start() ->
    application:ensure_all_started(erlmcp).

%% @doc Stop the erlmcp application.
stop() ->
    application:stop(erlmcp).

%% @doc Return the protocol version this library implements.
protocol_version() ->
    erlmcp_protocol:protocol_version().

%%--------------------------------------------------------------------
%% Client connection helpers
%%--------------------------------------------------------------------

%% @doc Start a client connection over STDIO using the default
%%      standard_io devices.
start_stdio_client() ->
    start_stdio_client(#{}).

%% @doc Start a client connection over STDIO.
%%
%% Options are forwarded to erlmcp_transport_stdio:start_link/1
%% and erlmcp_client_connection:start_link/2.
start_stdio_client(Options) when is_map(Options) ->
    TransportOpts = maps:with(
        [input_device, output_device, max_line_bytes],
        Options
    ),
    ConnectionOpts = maps:with(
        [request_timeout, max_pending],
        Options
    ),

    case erlmcp_transport_stdio:start_link(TransportOpts) of
        {ok, Transport} ->
            case erlmcp_client_connection:start_link(Transport, ConnectionOpts) of
                {ok, Connection} ->
                    {ok, #{transport => Transport, connection => Connection}};
                {error, Reason} ->
                    erlmcp_transport_stdio:stop(Transport),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Start a client connection over Streamable HTTP.
%%
%% Url must be a binary or string pointing at the MCP endpoint.
start_http_client(Url) ->
    start_http_client(Url, #{}).

%% @doc Start a client connection over Streamable HTTP with options.
%%
%% Supported options:
%%   request_timeout  - milliseconds (default 30000)
%%   max_pending      - concurrent request limit
%%   headers          - extra HTTP headers (list of {binary(), binary()})
%%   http_options     - options passed to the underlying HTTP client
start_http_client(Url, Options)
        when (is_binary(Url) orelse is_list(Url)), is_map(Options) ->
    case erlmcp_transport_http:start_link(Url, Options) of
        {ok, Transport} ->
            ConnectionOpts = maps:with(
                [request_timeout, max_pending],
                Options
            ),
            case erlmcp_client_connection:start_link(Transport, ConnectionOpts) of
                {ok, Connection} ->
                    {ok, #{transport => Transport, connection => Connection}};
                {error, Reason} ->
                    erlmcp_transport_http:stop(Transport),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end;
start_http_client(_Url, _Options) ->
    {error, invalid_options}.

%%--------------------------------------------------------------------
%% Server-side tool registry helpers
%%--------------------------------------------------------------------

%% @doc Register a tool with the local registry.
%%
%% Tool must be a map containing at least:
%%   name         - binary()
%%   input_schema - map() with <<"type">> => <<"object">>
%%   handler      - fun((map()) -> term())
register_tool(Tool) ->
    erlmcp_tool_registry:register_tool(Tool).

%% @doc Unregister a tool by name.
unregister_tool(Name) ->
    erlmcp_tool_registry:unregister_tool(Name).

%% @doc List the public MCP definitions of all registered tools.
list_tools() ->
    erlmcp_tool_registry:list_tools().
