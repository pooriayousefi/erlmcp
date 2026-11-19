%%--------------------------------------------------------------------
%% @doc
%% MCP client connection and request-correlation manager.
%%
%% This module sits between erlmcp_client and a transport process.
%% It forwards JSON-RPC requests to the transport, tracks outstanding
%% requests by JSON-RPC ID, and delivers matching responses to callers.
%%
%% Responsibilities:
%%   - Support multiple concurrent in-flight requests.
%%   - Correlate responses with their originating callers.
%%   - Enforce request timeouts and a configurable pending-request limit.
%%   - Monitor transport and caller processes.
%%   - Propagate transport failures to outstanding callers.
%%
%% The transport is deliberately abstract. STDIO and HTTP transport
%% modules communicate with this module through the message contract
%% documented in this module.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_client_connection).

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

-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_MAX_PENDING, 128).

-record(state, {
    transport,
    transport_monitor,
    pending = #{},
    caller_monitors = #{},
    request_timeout = ?DEFAULT_REQUEST_TIMEOUT,
    max_pending = ?DEFAULT_MAX_PENDING
}).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Starts a connection using the default configuration.
start_link(Transport) when is_pid(Transport) ->
    start_link(Transport, #{}).

%% @doc Starts a connection with configurable request handling limits.
%%
%% Options:
%%   request_timeout - Default request timeout in milliseconds.
%%                     Defaults to 30000. May be infinity.
%%   max_pending     - Maximum number of simultaneous requests.
%%                     Defaults to 128.
start_link(Transport, Options)
    when is_pid(Transport), is_map(Options) ->
    gen_server:start_link(?MODULE, {Transport, Options}, []).

%% @doc Stops the connection.
stop(Connection) ->
    gen_server:stop(Connection).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Transport, Options}) ->
    RequestTimeout = maps:get(
        request_timeout,
        Options,
        ?DEFAULT_REQUEST_TIMEOUT
    ),
    MaxPending = maps:get(
        max_pending,
        Options,
        ?DEFAULT_MAX_PENDING
    ),

    case valid_options(RequestTimeout, MaxPending) of
        true ->
            TransportMonitor = erlang:monitor(process, Transport),
            {ok, #state{
                transport = Transport,
                transport_monitor = TransportMonitor,
                request_timeout = RequestTimeout,
                max_pending = MaxPending
            }};
        false ->
            {stop, invalid_options}
    end.

handle_call({request, Request}, From, State) ->
    handle_request(Request, From, State);

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_operation}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% A transport delivers a decoded JSON-RPC response using this message.
handle_info(
    {erlmcp_transport, Transport, {data, Response}},
    #state{transport = Transport} = State
) when is_map(Response) ->
    handle_transport_response(Response, State);

%% A transport reports an operational failure.
handle_info(
    {erlmcp_transport, Transport, {error, Reason}},
    #state{transport = Transport} = State
) ->
    {noreply, fail_all_pending({transport_error, Reason}, State)};

%% A transport reports that it has closed.
handle_info(
    {erlmcp_transport, Transport, closed},
    #state{transport = Transport} = State
) ->
    {noreply, fail_all_pending(transport_closed, State)};

%% A request has exceeded its configured timeout.
handle_info(
    {request_timeout, Id, TimerRef},
    State
) ->
    case maps:find(Id, State#state.pending) of
        {ok, #{timer := TimerRef} = Entry} ->
            gen_server:reply(maps:get(from, Entry), {error, timeout}),
            {noreply, remove_pending(Id, State)};
        _ ->
            {noreply, State}
    end;

%% A caller has terminated while its request is outstanding.
handle_info(
    {'DOWN', Monitor, process, _Pid, _Reason},
    State
) ->
    case maps:find(Monitor, State#state.caller_monitors) of
        {ok, Id} ->
            {noreply, remove_pending(Id, State)};
        error ->
            handle_process_down(Monitor, State)
    end;

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    erlang:demonitor(State#state.transport_monitor, [flush]),
    _ = fail_all_pending(connection_stopped, State),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Request handling
%%====================================================================

handle_request(Request, From, State) ->
    case erlmcp_jsonrpc:validate(Request) of
        {ok, request} ->
            handle_valid_request(Request, From, State);
        {ok, _OtherType} ->
            {reply, {error, invalid_request}, State};
        {error, _Reason} ->
            {reply, {error, invalid_request}, State}
    end.

handle_valid_request(Request, From, State) ->
    Id = maps:get(<<"id">>, Request),

    case maps:is_key(Id, State#state.pending) of
        true ->
            {reply, {error, {duplicate_request_id, Id}}, State};
        false ->
            case map_size(State#state.pending) >= State#state.max_pending of
                true ->
                    {reply, {error, overloaded}, State};
                false ->
                    start_pending_request(Id, Request, From, State)
            end
    end.

start_pending_request(Id, Request, From, State) ->
    CallerPid = element(1, From),
    CallerMonitor = erlang:monitor(process, CallerPid),
    TimerRef = start_request_timer(Id, State#state.request_timeout),

    Entry = #{
        from => From,
        timer => TimerRef,
        caller_monitor => CallerMonitor
    },

    Pending = (State#state.pending)#{Id => Entry},
    CallerMonitors = (State#state.caller_monitors)#{CallerMonitor => Id},

    State1 = State#state{
        pending = Pending,
        caller_monitors = CallerMonitors
    },

    TransportMessage = {
        erlmcp_client_connection,
        self(),
        {send, Request}
    },

    State1#state.transport ! TransportMessage,

    {noreply, State1}.

start_request_timer(_Id, infinity) ->
    undefined;
start_request_timer(Id, Timeout) ->
    TimerRef = make_ref(),
    _ = erlang:send_after(
        Timeout,
        self(),
        {request_timeout, Id, TimerRef}
    ),
    TimerRef.

%%====================================================================
%% Response handling
%%====================================================================

handle_transport_response(Response, State) ->
    case maps:find(<<"id">>, Response) of
        {ok, Id} ->
            case maps:is_key(Id, State#state.pending) of
                true ->
                    Entry = maps:get(Id, State#state.pending),
                    gen_server:reply(maps:get(from, Entry), Response),
                    {noreply, remove_pending(Id, State)};
                false ->
                    %% Ignore responses that do not match an outstanding
                    %% request. This includes late and duplicate responses.
                    {noreply, State}
            end;
        error ->
            {noreply, State}
    end.

%%====================================================================
%% Process monitoring
%%====================================================================

handle_process_down(Monitor, State) ->
    case Monitor =:= State#state.transport_monitor of
        true ->
            {noreply, fail_all_pending(
                {transport_down, transport_down_reason()},
                State
            )};
        false ->
            {noreply, State}
    end.

transport_down_reason() ->
    transport_terminated.

%%====================================================================
%% Pending request management
%%====================================================================

remove_pending(Id, State) ->
    case maps:take(Id, State#state.pending) of
        {Entry, Pending} ->
            cancel_request_timer(maps:get(timer, Entry)),
            CallerMonitor = maps:get(caller_monitor, Entry),
            erlang:demonitor(CallerMonitor, [flush]),

            CallerMonitors = maps:remove(
                CallerMonitor,
                State#state.caller_monitors
            ),

            State#state{
                pending = Pending,
                caller_monitors = CallerMonitors
            };
        error ->
            State
    end.

cancel_request_timer(undefined) ->
    ok;
cancel_request_timer(TimerRef) ->
    _ = erlang:cancel_timer(TimerRef),
    ok.

fail_all_pending(Reason, State) ->
    maps:foreach(
        fun(_Id, Entry) ->
            cancel_request_timer(maps:get(timer, Entry)),
            erlang:demonitor(maps:get(caller_monitor, Entry), [flush]),
            gen_server:reply(
                maps:get(from, Entry),
                {error, Reason}
            )
        end,
        State#state.pending
    ),

    State#state{
        pending = #{},
        caller_monitors = #{}
    }.

%%====================================================================
%% Validation
%%====================================================================

valid_options(RequestTimeout, MaxPending) ->
    valid_request_timeout(RequestTimeout)
        andalso is_integer(MaxPending)
        andalso MaxPending > 0.

valid_request_timeout(infinity) ->
    true;
valid_request_timeout(Timeout) ->
    is_integer(Timeout) andalso Timeout > 0.