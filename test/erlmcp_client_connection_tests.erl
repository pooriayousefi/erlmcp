
%%--------------------------------------------------------------------
%% @doc
%% EUnit tests for erlmcp_client_connection.
%%
%% Tests request forwarding, response correlation, concurrent requests,
%% timeouts, pending-request limits, duplicate IDs, and transport failure.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_client_connection_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Tests
%%====================================================================

request_response_test() ->
    with_connection(
        #{},
        fun(Connection, Transport) ->
            Request = request(1),
            Parent = self(),

            spawn(fun() ->
                Parent ! {
                    result,
                    gen_server:call(
                        Connection,
                        {request, Request},
                        1000
                    )
                }
            end),

            receive
                {sent, Connection, Request} ->
                    Connection ! {
                        erlmcp_transport,
                        Transport,
                        {data, response(1)}
                    }
            after 1000 ->
                ?assert(false)
            end,

            receive
                {result, Result} ->
                    ?assertEqual(response(1), Result)
            after 1000 ->
                ?assert(false)
            end
        end
    ).

concurrent_request_correlation_test() ->
    with_connection(
        #{},
        fun(Connection, Transport) ->
            Parent = self(),

            spawn(fun() ->
                Parent ! {
                    first,
                    gen_server:call(
                        Connection,
                        {request, request(1)},
                        1000
                    )
                }
            end),

            spawn(fun() ->
                Parent ! {
                    second,
                    gen_server:call(
                        Connection,
                        {request, request(2)},
                        1000
                    )
                }
            end),

            receive
                {sent, Connection, _Request1} -> ok
            after 1000 ->
                ?assert(false)
            end,

            receive
                {sent, Connection, _Request2} -> ok
            after 1000 ->
                ?assert(false)
            end,

            %% Responses deliberately arrive in reverse order.
            Connection ! {
                erlmcp_transport,
                Transport,
                {data, response(2)}
            },

            Connection ! {
                erlmcp_transport,
                Transport,
                {data, response(1)}
            },

            Results = collect_results(2, #{}),

            ?assertEqual(response(1), maps:get(first, Results)),
            ?assertEqual(response(2), maps:get(second, Results))
        end
    ).

request_timeout_test() ->
    with_connection(
        #{request_timeout => 30},
        fun(Connection, _Transport) ->
            Result = gen_server:call(
                Connection,
                {request, request(1)},
                1000
            ),

            ?assertEqual({error, timeout}, Result)
        end
    ).

max_pending_test() ->
    with_connection(
        #{max_pending => 1, request_timeout => 500},
        fun(Connection, _Transport) ->
            Parent = self(),

            spawn(fun() ->
                Parent ! {
                    first,
                    gen_server:call(
                        Connection,
                        {request, request(1)},
                        1000
                    )
                }
            end),

            receive
                {sent, Connection, _Request} -> ok
            after 1000 ->
                ?assert(false)
            end,

            Result = gen_server:call(
                Connection,
                {request, request(2)},
                1000
            ),

            ?assertEqual({error, overloaded}, Result)
        end
    ).

duplicate_request_id_test() ->
    with_connection(
        #{request_timeout => 500},
        fun(Connection, _Transport) ->
            Parent = self(),

            spawn(fun() ->
                Parent ! {
                    first,
                    gen_server:call(
                        Connection,
                        {request, request(1)},
                        1000
                    )
                }
            end),

            receive
                {sent, Connection, _Request} -> ok
            after 1000 ->
                ?assert(false)
            end,

            Result = gen_server:call(
                Connection,
                {request, request(1)},
                1000
            ),

            ?assertEqual(
                {error, {duplicate_request_id, 1}},
                Result
            )
        end
    ).

transport_error_test() ->
    with_connection(
        #{request_timeout => 1000},
        fun(Connection, Transport) ->
            Parent = self(),

            spawn(fun() ->
                Parent ! {
                    result,
                    gen_server:call(
                        Connection,
                        {request, request(1)},
                        1500
                    )
                }
            end),

            receive
                {sent, Connection, _Request} -> ok
            after 1000 ->
                ?assert(false)
            end,

            Connection ! {
                erlmcp_transport,
                Transport,
                {error, connection_lost}
            },

            receive
                {result, Result} ->
                    ?assertEqual(
                        {error, {transport_error, connection_lost}},
                        Result
                    )
            after 1000 ->
                ?assert(false)
            end
        end
    ).

%%====================================================================
%% Test helpers
%%====================================================================

with_connection(Options, TestFun) ->
    Parent = self(),

    Transport = spawn(fun() ->
        transport_loop(Parent)
    end),

    {ok, Connection} =
        erlmcp_client_connection:start_link(Transport, Options),

    try
        TestFun(Connection, Transport)
    after
        try
            erlmcp_client_connection:stop(Connection)
        catch
            _:_ ->
                ok
        end,

        exit(Transport, kill)
    end.

transport_loop(Parent) ->
    receive
        {
            erlmcp_client_connection,
            Connection,
            {send, Request}
        } ->
            Parent ! {sent, Connection, Request},
            transport_loop(Parent);
        _Other ->
            transport_loop(Parent)
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
        <<"result">> => #{<<"ok">> => true}
    }.

collect_results(0, Results) ->
    Results;
collect_results(Count, Results) ->
    receive
        {first, Result} ->
            collect_results(Count - 1, Results#{first => Result});
        {second, Result} ->
            collect_results(Count - 1, Results#{second => Result})
    after 1000 ->
        ?assert(false)
    end.
