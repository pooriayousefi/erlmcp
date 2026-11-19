
%%--------------------------------------------------------------------
%% @doc
%% Newline-delimited JSON transport for MCP clients.
%%
%% This module connects an erlmcp_client_connection process to an MCP
%% server through standard input and standard output.
%%
%% Responsibilities:
%%   - Encode outgoing JSON-RPC messages as NDJSON.
%%   - Read incoming newline-delimited JSON messages.
%%   - Decode and validate incoming JSON-RPC messages.
%%   - Forward decoded messages to the associated client connection.
%%   - Report input termination, malformed messages, and IO failures.
%%
%% The transport is dedicated to one client connection and binds to
%% that connection when it receives its first outgoing request.
%% No MCP session or protocol handshake is maintained here.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_transport_stdio).

-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    stop/1,
    encode_message/1,
    decode_message/1,
    decode_message/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_MAX_LINE_BYTES, 1048576).

-record(state, {
    input_device = standard_io,
    output_device = standard_io,
    max_line_bytes = ?DEFAULT_MAX_LINE_BYTES,
    connection = undefined,
    reader_pid = undefined,
    reader_monitor = undefined
}).

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    start_link(#{}).

start_link(Options) when is_map(Options) ->
    gen_server:start_link(?MODULE, Options, []);
start_link(_Options) ->
    {error, invalid_options}.

stop(Transport) ->
    gen_server:stop(Transport).

encode_message(Message) when is_map(Message) ->
    case erlmcp_jsonrpc:validate(Message) of
        {ok, _MessageType} ->
            try
                Encoded = iolist_to_binary(json:encode(Message)),
                {ok, <<Encoded/binary, "\n">>}
            catch
                EncodeClass:EncodeReason ->
                    {error, {
                        json_encode_failed,
                        EncodeClass,
                        EncodeReason
                    }}
            end;
        {error, ValidationReason} ->
            {error, {invalid_jsonrpc_message, ValidationReason}}
    end;
encode_message(_Message) ->
    {error, invalid_message}.

decode_message(Line) ->
    decode_message(Line, ?DEFAULT_MAX_LINE_BYTES).

decode_message(Line, MaxLineBytes)
    when is_integer(MaxLineBytes), MaxLineBytes > 0 ->
    case normalize_line(Line) of
        {ok, Binary} ->
            decode_normalized_line(Binary, MaxLineBytes);
        {error, _Reason} = Error ->
            Error
    end;
decode_message(_Line, _MaxLineBytes) ->
    {error, invalid_max_line_bytes}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Options) ->
    InputDevice = maps:get(input_device, Options, standard_io),
    OutputDevice = maps:get(output_device, Options, standard_io),
    MaxLineBytes = maps:get(
        max_line_bytes,
        Options,
        ?DEFAULT_MAX_LINE_BYTES
    ),

    case valid_max_line_bytes(MaxLineBytes) of
        true ->
            {ok, #state{
                input_device = InputDevice,
                output_device = OutputDevice,
                max_line_bytes = MaxLineBytes
            }};
        false ->
            {stop, invalid_max_line_bytes}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_operation}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(
    {
        erlmcp_client_connection,
        Connection,
        {send, Request}
    },
    State
) when is_pid(Connection) ->
    handle_outgoing_request(Connection, Request, State);

handle_info(
    {stdio_line, ReaderPid, Line},
    #state{reader_pid = ReaderPid} = State
) ->
    handle_incoming_line(Line, State);

handle_info(
    {stdio_eof, ReaderPid},
    #state{reader_pid = ReaderPid} = State
) ->
    notify_connection(closed, State),
    {stop, normal, State};

handle_info(
    {stdio_read_error, ReaderPid, ReadReason},
    #state{reader_pid = ReaderPid} = State
) ->
    notify_connection(
        {error, {stdio_read_failed, ReadReason}},
        State
    ),
    {stop, normal, State};

handle_info(
    {'DOWN', Monitor, process, ReaderPid, DownReason},
    #state{
        reader_pid = ReaderPid,
        reader_monitor = Monitor
    } = State
) ->
    case DownReason of
        normal ->
            {noreply, State};
        _ ->
            notify_connection(
                {error, {stdio_reader_terminated, DownReason}},
                State
            ),
            {stop, normal, State}
    end;

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.reader_pid of
        undefined ->
            ok;
        ReaderPid ->
            exit(ReaderPid, kill)
    end,

    case State#state.reader_monitor of
        undefined ->
            ok;
        Monitor ->
            erlang:demonitor(Monitor, [flush])
    end,

    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Outgoing messages
%%====================================================================

handle_outgoing_request(Connection, Request, State) ->
    case bind_connection(Connection, State) of
        {ok, BoundState} ->
            case encode_message(Request) of
                {ok, Line} ->
                    write_and_start_reader(Line, BoundState);
                {error, EncodeReason} ->
                    notify_connection(
                        {error, {stdio_encode_failed, EncodeReason}},
                        BoundState
                    ),
                    {stop, normal, BoundState}
            end;
        {error, BindReason} ->
            Connection ! {
                erlmcp_transport,
                self(),
                {error, BindReason}
            },
            {noreply, State}
    end.

bind_connection(
    Connection,
    #state{connection = undefined} = State
) ->
    {ok, State#state{connection = Connection}};
bind_connection(
    Connection,
    #state{connection = Connection} = State
) ->
    {ok, State};
bind_connection(_Connection, _State) ->
    {error, connection_already_bound}.

write_and_start_reader(Line, State) ->
    case write_line(State#state.output_device, Line) of
        ok ->
            start_reader(State);
        {error, WriteReason} ->
            notify_connection(
                {error, {stdio_write_failed, WriteReason}},
                State
            ),
            {stop, normal, State}
    end.

write_line(OutputDevice, Line) ->
    try
        case io:put_chars(OutputDevice, Line) of
            ok ->
                ok;
            {error, IoReason} ->
                {error, IoReason};
            OtherResult ->
                {error, {unexpected_io_result, OtherResult}}
        end
    catch
        WriteClass:WriteException ->
            {error, {WriteClass, WriteException}}
    end.

start_reader(#state{reader_pid = undefined} = State) ->
    Parent = self(),
    InputDevice = State#state.input_device,

    {ReaderPid, Monitor} = spawn_monitor(fun() ->
        reader_loop(Parent, InputDevice)
    end),

    {noreply, State#state{
        reader_pid = ReaderPid,
        reader_monitor = Monitor
    }};
start_reader(State) ->
    {noreply, State}.

%%====================================================================
%% Incoming messages
%%====================================================================

handle_incoming_line(Line, State) ->
    case decode_message(Line, State#state.max_line_bytes) of
        {ok, Message} ->
            notify_connection({data, Message}, State),
            {noreply, State};
        {error, DecodeReason} ->
            notify_connection(
                {error, {stdio_decode_failed, DecodeReason}},
                State
            ),
            {stop, normal, State}
    end.

notify_connection(_Event, #state{connection = undefined}) ->
    ok;
notify_connection(Event, State) ->
    State#state.connection ! {
        erlmcp_transport,
        self(),
        Event
    },
    ok.

%%====================================================================
%% Reader process
%%====================================================================

reader_loop(Parent, InputDevice) ->
    try
        case io:get_line(InputDevice, "") of
            eof ->
                Parent ! {stdio_eof, self()};
            {error, ReadReason} ->
                Parent ! {stdio_read_error, self(), ReadReason};
            Line when is_list(Line) ->
                Parent ! {stdio_line, self(), Line},
                reader_loop(Parent, InputDevice);
            Line when is_binary(Line) ->
                Parent ! {stdio_line, self(), Line},
                reader_loop(Parent, InputDevice);
            OtherResult ->
                Parent ! {
                    stdio_read_error,
                    self(),
                    {unexpected_io_result, OtherResult}
                }
        end
    catch
        ReaderClass:ReaderException ->
            Parent ! {
                stdio_read_error,
                self(),
                {ReaderClass, ReaderException}
            }
    end.

%%====================================================================
%% JSON and line handling
%%====================================================================

normalize_line(Line) when is_binary(Line) ->
    {ok, strip_line_ending(Line)};
normalize_line(Line) when is_list(Line) ->
    try
        Binary = unicode:characters_to_binary(Line),
        case is_binary(Binary) of
            true ->
                {ok, strip_line_ending(Binary)};
            false ->
                {error, invalid_unicode}
        end
    catch
        UnicodeClass:UnicodeReason ->
            {error, {invalid_unicode, UnicodeClass, UnicodeReason}}
    end;
normalize_line(_Line) ->
    {error, invalid_line}.

strip_line_ending(Binary) ->
    WithoutLf = case byte_size(Binary) of
        0 ->
            Binary;
        Size ->
            case binary:at(Binary, Size - 1) of
                $\n ->
                    binary:part(Binary, 0, Size - 1);
                _ ->
                    Binary
            end
    end,

    case byte_size(WithoutLf) of
        0 ->
            WithoutLf;
        Size2 ->
            case binary:at(WithoutLf, Size2 - 1) of
                $\r ->
                    binary:part(WithoutLf, 0, Size2 - 1);
                _ ->
                    WithoutLf
            end
    end.

decode_normalized_line(Binary, MaxLineBytes) ->
    case byte_size(Binary) =< MaxLineBytes of
        false ->
            {error, line_too_large};
        true ->
            decode_jsonrpc(Binary)
    end.

decode_jsonrpc(<<>>) ->
    {error, empty_line};
decode_jsonrpc(Binary) ->
    try
        case json:decode(Binary) of
            Message when is_map(Message) ->
                case erlmcp_jsonrpc:validate(Message) of
                    {ok, _MessageType} ->
                        {ok, Message};
                    {error, ValidationReason} ->
                        {error, {
                            invalid_jsonrpc_message,
                            ValidationReason
                        }}
                end;
            _Other ->
                {error, jsonrpc_message_must_be_object}
        end
    catch
        DecodeClass:DecodeException ->
            {error, {
                invalid_json,
                DecodeClass,
                DecodeException
            }}
    end.

%%====================================================================
%% Configuration validation
%%====================================================================

valid_max_line_bytes(MaxLineBytes) ->
    is_integer(MaxLineBytes) andalso MaxLineBytes > 0.
