%%--------------------------------------------------------------------
%% @doc Additional EUnit coverage for client-connection failure paths.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_client_connection_edge_tests).

-include_lib("eunit/include/eunit.hrl").

invalid_start_options_test() ->
    Transport = start_transport(),
    try
        ?assertEqual(
            {error, invalid_options},
            start_with_invalid_options(Transport, #{request_timeout => 0})
        )
    after
        cleanup(fun() -> exit(Transport, kill) end)
    end.

invalid_max_pending_test() ->
    Transport = start_transport(),
    try
        ?assertEqual(
            {error, invalid_options},
            start_with_invalid_options(Transport, #{max_pending => 0})
        )
    after
        cleanup(fun() -> exit(Transport, kill) end)
    end.

%% gen_server:start_link/3 reports an init failure as {error, Reason}.
%% OTP removes the temporary link when startup fails, so no EXIT signal
%% should be expected by the caller.
start_with_invalid_options(Transport, Options) ->
    erlmcp_client_connection:start_link(Transport, Options).

invalid_request_test() ->
    with_connection(fun(Connection, _Transport) ->
        ?assertEqual({error, invalid_request},
            gen_server:call(Connection, {request, #{}}, 1000))
    end).

transport_closed_test() ->
    with_pending_request(fun(Connection, Transport, Caller) ->
        Connection ! {erlmcp_transport, Transport, closed},
        assert_caller_result({error, transport_closed}),
        exit(Caller, kill)
    end).

transport_process_down_test() ->
    with_pending_request(fun(Connection, Transport, Caller) ->
        exit(Transport, kill),
        assert_caller_result({error, {transport_down, transport_terminated}}),
        ?assert(is_process_alive(Connection)),
        exit(Caller, kill)
    end).

unmatched_response_is_ignored_test() ->
    with_pending_request(fun(Connection, Transport, Caller) ->
        Connection ! {erlmcp_transport, Transport, {data, response(999)}},
        ?assert(is_process_alive(Connection)),
        Connection ! {erlmcp_transport, Transport, {data, response(7)}},
        assert_caller_result(response(7)),
        exit(Caller, kill)
    end).

caller_exit_cleans_pending_test() ->
    with_connection(fun(Connection, Transport) ->
        Caller = spawn(fun() ->
            gen_server:call(Connection, {request, request(8)}, 5000)
        end),
        wait_for_sent(),
        exit(Caller, kill),
        Parent = self(),
        spawn(fun() ->
            Parent ! {second_result, gen_server:call(
                Connection, {request, request(9)}, 1000
            )}
        end),
        wait_for_sent(),
        Connection ! {erlmcp_transport, Transport, {data, response(9)}},
        receive
            {second_result, Result} -> ?assertEqual(response(9), Result)
        after 1000 -> ?assert(false)
        end
    end).

with_pending_request(Test) ->
    Parent = self(),
    Transport = start_transport(),
    {ok, Connection} = erlmcp_client_connection:start_link(
        Transport, #{request_timeout => 3000}
    ),
    Caller = spawn(fun() ->
        Result = gen_server:call(Connection, {request, request(7)}, 4000),
        Parent ! {caller_result, Result}
    end),
    receive
        {transport_sent, Connection, _Request} -> ok
    after 1000 -> ?assert(false)
    end,
    try Test(Connection, Transport, Caller)
    after
        cleanup(fun() -> erlmcp_client_connection:stop(Connection) end),
        cleanup(fun() -> exit(Transport, kill) end)
    end.

with_connection(Test) ->
    Transport = start_transport(),
    {ok, Connection} = erlmcp_client_connection:start_link(Transport, #{}),
    try Test(Connection, Transport)
    after
        cleanup(fun() -> erlmcp_client_connection:stop(Connection) end),
        cleanup(fun() -> exit(Transport, kill) end)
    end.

cleanup(Fun) ->
    try Fun() catch _:_ -> ok end.

start_transport() ->
    Parent = self(),
    spawn(fun() -> transport_loop(Parent) end).

transport_loop(Parent) ->
    receive
        {erlmcp_client_connection, Connection, {send, Request}} ->
            Parent ! {transport_sent, Connection, Request},
            transport_loop(Parent);
        _ -> transport_loop(Parent)
    end.

wait_for_sent() ->
    receive
        {transport_sent, _Connection, _Request} -> ok
    after 1000 -> ?assert(false)
    end.

assert_caller_result(Expected) ->
    receive
        {caller_result, Result} -> ?assertEqual(Expected, Result)
    after 1000 -> ?assert(false)
    end.

request(Id) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"method">> => <<"test/method">>, <<"params">> => #{}}.

response(Id) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"result">> => #{<<"ok">> => true}}.
