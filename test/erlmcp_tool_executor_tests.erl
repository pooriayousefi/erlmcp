
-module(erlmcp_tool_executor_tests).

-include_lib("eunit/include/eunit.hrl").

execute_tool_test() ->
    with_services(fun() ->
        ok = register_test_tool(
            fun(Arguments) ->
                maps:get(<<"value">>, Arguments)
            end
        ),
        ?assertEqual(
            {ok, 42},
            erlmcp_tool_executor:execute_tool(
                <<"test_tool">>,
                #{<<"value">> => 42}
            )
        )
    end).

unknown_tool_test() ->
    with_services(fun() ->
        ?assertEqual(
            {error, not_found},
            erlmcp_tool_executor:execute_tool(
                <<"unknown">>,
                #{}
            )
        )
    end).

invalid_arguments_test() ->
    with_services(fun() ->
        ok = register_test_tool(fun(_Arguments) -> ok end),
        ?assertEqual(
            {error, invalid_arguments},
            erlmcp_tool_executor:execute_tool(
                <<"test_tool">>,
                not_a_map
            )
        )
    end).

handler_exception_test() ->
    with_services(fun() ->
        ok = register_test_tool(
            fun(_Arguments) ->
                erlang:error(test_failure)
            end
        ),
        ?assertEqual(
            {error, {execution_failed, error, test_failure}},
            erlmcp_tool_executor:execute_tool(
                <<"test_tool">>,
                #{}
            )
        )
    end).

execution_timeout_test() ->
    with_services(fun() ->
        ok = register_test_tool(
            fun(_Arguments) ->
                timer:sleep(200),
                completed
            end
        ),
        ?assertEqual(
            {error, timeout},
            erlmcp_tool_executor:execute_tool(
                <<"test_tool">>,
                #{},
                20
            )
        )
    end).

invalid_timeout_test() ->
    with_services(fun() ->
        ?assertEqual(
            {error, invalid_timeout},
            erlmcp_tool_executor:execute_tool(
                <<"test_tool">>,
                #{},
                0
            )
        )
    end).

concurrent_execution_test() ->
    with_services(fun() ->
        ok = register_test_tool(
            fun(_Arguments) ->
                timer:sleep(150),
                completed
            end
        ),

        Parent = self(),

        spawn(fun() ->
            Parent ! {
                first_result,
                erlmcp_tool_executor:execute_tool(
                    <<"test_tool">>,
                    #{}
                )
            }
        end),

        spawn(fun() ->
            Parent ! {
                second_result,
                erlmcp_tool_executor:execute_tool(
                    <<"test_tool">>,
                    #{}
                )
            }
        end),

        ?assertEqual(
            {ok, completed},
            receive_result(first_result)
        ),
        ?assertEqual(
            {ok, completed},
            receive_result(second_result)
        )
    end).

receive_result(Tag) ->
    receive
        {Tag, Result} ->
            Result
    after 2000 ->
        timeout
    end.

register_test_tool(Handler) ->
    erlmcp_tool_registry:register_tool(#{
        name => <<"test_tool">>,
        description => <<"Executor test tool">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{}
        },
        handler => Handler
    }).

with_services(Test) ->
    {ok, RegistryPid} = erlmcp_tool_registry:start_link(),
    try
        {ok, ExecutorPid} = erlmcp_tool_executor:start_link(),
        try
            Test()
        after
            gen_server:stop(ExecutorPid)
        end
    after
        gen_server:stop(RegistryPid)
    end.
