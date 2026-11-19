# erlmcp

Stateless **Model Context Protocol** (MCP) client and server library for Erlang/OTP, targeting protocol version **2026-07-28**.

## Features (v0.1.0)

| Area                    | Status |
|-------------------------|--------|
| JSON-RPC 2.0            | Complete validation, construction, errors, notifications |
| MCP protocol 2026-07-28 | Stateless `_meta`, `server/discover`, `resultType`, MRTR (`input_required`) |
| Tools                   | Registration, discovery, JSON Schema, concurrent execution with timeouts |
| MCP client              | Discovery, tool listing, tool invocation, response validation |
| MCP server              | Dispatch, tool execution, error mapping |
| STDIO transport         | Newline-delimited JSON (client side) |
| Streamable HTTP         | Client transport (POST + headers + JSON/SSE) + minimal server handler |
| Concurrency             | Request correlation, pending-request limits, process isolation |
| Reliability             | Timeouts, cancellation via process monitors, back-pressure |

## Quick start

### As a library (rebar3 / mix)

Add to your `rebar.config` (or equivalent) and start the application:

```erlang
{ok, _} = erlmcp:start().
```

### Register a tool (server side)

```erlang
erlmcp:register_tool(#{
    name => <<"echo">>,
    description => <<"Echo the input text">>,
    input_schema => #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"text">> => #{<<"type">> => <<"string">>}
        },
        <<"required">> => [<<"text">>]
    },
    handler => fun(#{<<"text">> := Text}) ->
        #{content => [#{<<"type">> => <<"text">>, <<"text">> => Text}]}
    end
}).
```

### Client over STDIO

```erlang
{ok, #{connection := Conn}} = erlmcp:start_stdio_client(),
{ok, Discover} = erlmcp_client:discover(Conn),
{ok, Tools}    = erlmcp_client:list_tools(Conn),
{ok, Result}   = erlmcp_client:call_tool(Conn, <<"echo">>, #{<<"text">> => <<"hello">>}).
```

### Client over Streamable HTTP

```erlang
{ok, #{connection := Conn}} = erlmcp:start_http_client(<<"https://example.com/mcp">>),
{ok, Result} = erlmcp_client:call_tool(Conn, <<"echo">>, #{<<"text">> => <<"hello">>}).
```

### HTTP server integration (Cowboy sketch)

```erlang
%% In your Cowboy handler:
handle(Req, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    Headers = cowboy_req:headers(Req),
    case erlmcp_http_handler:handle(Body, Headers) of
        {ok, Status, RespHeaders, RespBody} ->
            cowboy_req:reply(Status, maps:from_list(RespHeaders), RespBody, Req1);
        {error, Status, ErrorBody} ->
            cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>},
                             ErrorBody, Req1)
    end,
    {ok, Req1, State}.
```

## Architecture

```
erlmcp_client  ──►  erlmcp_client_connection  ──►  transport (stdio | http)
                                                          │
                                                          ▼
erlmcp_server  ◄──  erlmcp_http_handler / stdio reader
       │
       ├── erlmcp_tool_registry
       └── erlmcp_tool_executor
```

- **Client path** is fully asynchronous and supports concurrent in-flight requests with correlation by JSON-RPC `id`.
- **Server path** is pure: `erlmcp_server:handle_message/1` has no process state. Transports and the HTTP handler are thin adapters around it.
- Tool handlers run in isolated monitored processes with per-call timeouts.

## Protocol notes (2026-07-28)

- No `initialize` handshake and no protocol-level sessions.
- Every request carries `io.modelcontextprotocol/protocolVersion`, client capabilities and (optionally) client info inside `params._meta`.
- `server/discover` is the recommended first call.
- Multi-round-trip requests return `resultType: "input_required"`. Automatic continuation is opt-in through the client's `input_handler` option; without it, the `input_required` result is returned to the application.
- The input handler is a function of arity 2: `fun(InputRequests, Context) -> {ok, InputResponses} | {error, Reason} end`. The context contains `tool_name`, original `arguments`, opaque `request_state`, and 1-based `round`. The client repeats the original tool call with `inputResponses` and the returned `requestState`, using a new JSON-RPC ID for each exchange.
- `call_tool/4` accepts `timeout` (one total deadline for all rounds), `max_input_rounds` (default 5), and `input_handler`. Callback exceptions, invalid callback results, and callback errors are returned as explicit client errors.
- Server tool handlers may use arity 1 (existing behavior) or arity 2. An arity-2 handler receives `fun(Arguments, Context)`; the context contains `input_responses` and/or `request_state` on continuation calls. To request more input, return `#{result_type => input_required, input_requests => Requests, request_state => OpaqueBinary}` (either `input_requests` or `request_state` is required).
- Streamable HTTP requires `MCP-Protocol-Version` and `Mcp-Method` headers (plus `Mcp-Name` for `tools/call`).

## Building & testing

```bash
rebar3 compile
rebar3 eunit
```

## License

Apache-2.0
```
