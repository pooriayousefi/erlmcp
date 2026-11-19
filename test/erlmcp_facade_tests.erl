%%--------------------------------------------------------------------
%% @doc EUnit tests for the public erlmcp facade and OTP callbacks.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_facade_tests).

-include_lib("eunit/include/eunit.hrl").

protocol_version_test() ->
    ?assertEqual(<<"2026-07-28">>, erlmcp:protocol_version()).

start_http_client_rejects_invalid_url_test() ->
    ?assertEqual({error, invalid_url}, erlmcp:start_http_client(<<>>)).

start_http_client_rejects_invalid_options_test() ->
    ?assertEqual(
        {error, invalid_options},
        erlmcp:start_http_client(<<"http://localhost/mcp">>, [])
    ).

registry_facade_test_() ->
    {setup,
        fun() ->
            {ok, Registry} = erlmcp_tool_registry:start_link(),
            Registry
        end,
        fun(Registry) ->
            catch gen_server:stop(Registry)
        end,
        fun(_Registry) ->
            ?_test(begin
                Tool = #{
                    name => <<"facade_echo">>,
                    description => <<"Echo">>,
                    input_schema => #{<<"type">> => <<"object">>},
                    handler => fun(Args) -> Args end
                },
                ?assertEqual(ok, erlmcp:register_tool(Tool)),
                ?assertEqual(
                    {ok, [#{
                        <<"name">> := <<"facade_echo">>,
                        <<"description">> := <<"Echo">>,
                        <<"inputSchema">> := #{<<"type">> := <<"object">>}
                    }]},
                    erlmcp:list_tools()
                ),
                ?assertEqual(ok, erlmcp:unregister_tool(<<"facade_echo">>)),
                ?assertEqual({ok, []}, erlmcp:list_tools())
            end)
        end
    }.

application_callback_test() ->
    {ok, Supervisor} = erlmcp_app:start(normal, []),
    Monitor = erlang:monitor(process, Supervisor),
    ?assert(is_process_alive(Supervisor)),
    ?assertEqual(ok, erlmcp_app:stop([])),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
    after 1000 ->
        ?assert(false)
    end.

supervisor_children_test() ->
    {ok, Supervisor} = erlmcp_sup:start_link(),
    unlink(Supervisor),
    try
        ?assert(is_pid(whereis(erlmcp_tool_registry))),
        ?assert(is_pid(whereis(erlmcp_tool_executor))),
        Children = supervisor:which_children(Supervisor),
        ?assertEqual(
            [erlmcp_tool_executor, erlmcp_tool_registry],
            lists:sort([Id || {Id, _Pid, worker, _Modules} <- Children])
        )
    after
        Monitor = erlang:monitor(process, Supervisor),
        exit(Supervisor, shutdown),
        receive
            {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
        after 1000 ->
            ?assert(false)
        end
    end.
