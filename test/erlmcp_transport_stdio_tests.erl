
%%--------------------------------------------------------------------
%% @doc
%% EUnit tests for erlmcp_transport_stdio.
%%
%% Tests NDJSON encoding and decoding, JSON-RPC validation, line
%% framing, maximum message size, and communication through the
%% client connection using file-backed IO devices.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_transport_stdio_tests).

-include_lib("eunit/include/eunit.hrl").

encode_request_test() ->
    Request = request(1),
    {ok, Encoded} = erlmcp_transport_stdio:encode_message(Request),

    ?assert(is_binary(Encoded)),
    ?assertEqual($\n, binary:last(Encoded)),
    ?assertEqual({ok, Request}, erlmcp_transport_stdio:decode_message(Encoded)).

decode_response_test() ->
    Response = response(1),
    Encoded = iolist_to_binary(json:encode(Response)),

    ?assertEqual(
        {ok, Response},
        erlmcp_transport_stdio:decode_message(Encoded)
    ).

decode_newline_test() ->
    Response = response(1),
    Encoded = iolist_to_binary(json:encode(Response)),
    Line = <<Encoded/binary, "\n">>,

    ?assertEqual(
        {ok, Response},
        erlmcp_transport_stdio:decode_message(Line)
    ).

decode_crlf_test() ->
    Response = response(1),
    Encoded = iolist_to_binary(json:encode(Response)),
    Line = <<Encoded/binary, "\r\n">>,

    ?assertEqual(
        {ok, Response},
        erlmcp_transport_stdio:decode_message(Line)
    ).

decode_invalid_json_test() ->
    ?assertMatch(
        {error, {invalid_json, _, _}},
        erlmcp_transport_stdio:decode_message(<<"{invalid}\n">>)
    ).

decode_invalid_jsonrpc_test() ->
    InvalidMessage = #{
        <<"jsonrpc">> => <<"1.0">>,
        <<"id">> => 1,
        <<"result">> => #{}
    },

    ?assertMatch(
        {error, {invalid_jsonrpc_message, _}},
        erlmcp_transport_stdio:decode_message(
            iolist_to_binary(json:encode(InvalidMessage))
        )
    ).

decode_non_object_test() ->
    ?assertEqual(
        {error, jsonrpc_message_must_be_object},
        erlmcp_transport_stdio:decode_message(<<"[]">>)
    ).

decode_empty_line_test() ->
    ?assertEqual(
        {error, empty_line},
        erlmcp_transport_stdio:decode_message(<<"\n">>)
    ).

decode_oversized_line_test() ->
    Response = response(1),
    Encoded = iolist_to_binary(json:encode(Response)),

    ?assertEqual(
        {error, line_too_large},
        erlmcp_transport_stdio:decode_message(
            Encoded,
            byte_size(Encoded) - 1
        )
    ).

encode_invalid_message_test() ->
    ?assertEqual(
        {error, invalid_message},
        erlmcp_transport_stdio:encode_message(not_a_map)
    ).

stdio_transport_round_trip_test() ->
    Suffix =
        integer_to_list(
            erlang:unique_integer([positive, monotonic])
        ),
    InputPath =
        filename:join("/tmp", "erlmcp_stdio_input_" ++ Suffix),
    OutputPath =
        filename:join("/tmp", "erlmcp_stdio_output_" ++ Suffix),

    ExpectedResponse = response(7),
    ResponseLine =
        <<(iolist_to_binary(json:encode(ExpectedResponse)))/binary, "\n">>,

    ok = file:write_file(InputPath, ResponseLine),
    {ok, InputDevice} = file:open(InputPath, [read]),
    {ok, OutputDevice} = file:open(OutputPath, [write]),

    try
        {ok, Transport} =
            erlmcp_transport_stdio:start_link(#{
                input_device => InputDevice,
                output_device => OutputDevice
            }),

        {ok, Connection} =
            erlmcp_client_connection:start_link(
                Transport,
                #{request_timeout => 2000}
            ),

        try
            Result =
                gen_server:call(
                    Connection,
                    {request, request(7)},
                    3000
                ),

            ?assertEqual(ExpectedResponse, Result)
        after
            try
                erlmcp_client_connection:stop(Connection)
            catch
                _:_ -> ok
            end,

            try
                erlmcp_transport_stdio:stop(Transport)
            catch
                _:_ -> ok
            end
        end
    after
        file:close(InputDevice),
        file:close(OutputDevice),
        file:delete(InputPath),
        file:delete(OutputPath)
    end.

request(Id) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"test/method">>,
        <<"params">> => #{}
    }.

response(Id) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{
            <<"ok">> => true
        }
    }.
