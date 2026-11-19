
-module(erlmcp_tool_registry_tests).

-include_lib("eunit/include/eunit.hrl").

register_tool_test() ->
    with_registry(fun() ->
        ?assertEqual(ok, erlmcp_tool_registry:register_tool(valid_tool()))
    end).

duplicate_tool_test() ->
    with_registry(fun() ->
        Tool = valid_tool(),
        ok = erlmcp_tool_registry:register_tool(Tool),
        ?assertEqual(
            {error, already_registered},
            erlmcp_tool_registry:register_tool(Tool)
        )
    end).

get_tool_test() ->
    with_registry(fun() ->
        Tool = valid_tool(),
        ok = erlmcp_tool_registry:register_tool(Tool),
        ?assertEqual(
            {ok, Tool},
            erlmcp_tool_registry:get_tool(<<"get_time">>)
        )
    end).

get_missing_tool_test() ->
    with_registry(fun() ->
        ?assertEqual(
            {error, not_found},
            erlmcp_tool_registry:get_tool(<<"unknown">>)
        )
    end).

list_tools_test() ->
    with_registry(fun() ->
        ok = erlmcp_tool_registry:register_tool(valid_tool()),
        {ok, [Definition]} = erlmcp_tool_registry:list_tools(),

        ?assertEqual(<<"get_time">>, maps:get(<<"name">>, Definition)),
        ?assertNot(maps:is_key(handler, Definition))
    end).

update_tool_test() ->
    with_registry(fun() ->
        Tool = valid_tool(),
        ok = erlmcp_tool_registry:register_tool(Tool),

        Updated = Tool#{description => <<"Updated description">>},
        ?assertEqual(ok, erlmcp_tool_registry:update_tool(Updated)),
        ?assertEqual(
            {ok, Updated},
            erlmcp_tool_registry:get_tool(<<"get_time">>)
        )
    end).

update_missing_tool_test() ->
    with_registry(fun() ->
        ?assertEqual(
            {error, not_found},
            erlmcp_tool_registry:update_tool(valid_tool())
        )
    end).

unregister_tool_test() ->
    with_registry(fun() ->
        ok = erlmcp_tool_registry:register_tool(valid_tool()),
        ?assertEqual(
            ok,
            erlmcp_tool_registry:unregister_tool(<<"get_time">>)
        ),
        ?assertEqual(
            {error, not_found},
            erlmcp_tool_registry:get_tool(<<"get_time">>)
        )
    end).

invalid_tool_test() ->
    with_registry(fun() ->
        ?assertEqual(
            {error, invalid_tool_definition},
            erlmcp_tool_registry:register_tool(not_a_map)
        )
    end).

missing_name_test() ->
    with_registry(fun() ->
        Tool = maps:remove(name, valid_tool()),
        ?assertEqual(
            {error, missing_tool_name},
            erlmcp_tool_registry:register_tool(Tool)
        )
    end).

invalid_schema_test() ->
    with_registry(fun() ->
        Tool0 = valid_tool(),
        Tool = Tool0#{
            input_schema => #{<<"type">> => <<"array">>}
        },
        ?assertEqual(
            {error, invalid_input_schema},
            erlmcp_tool_registry:register_tool(Tool)
        )
    end).

missing_handler_test() ->
    with_registry(fun() ->
        Tool = maps:remove(handler, valid_tool()),
        ?assertEqual(
            {error, missing_tool_handler},
            erlmcp_tool_registry:register_tool(Tool)
        )
    end).

%% Test helpers

with_registry(Test) ->
    {ok, Pid} = erlmcp_tool_registry:start_link(),
    try
        Test()
    after
        gen_server:stop(Pid)
    end.

valid_tool() ->
    #{
        name => <<"get_time">>,
        description => <<"Get the current time">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{}
        },
        handler => fun(_Arguments) -> ok end
    }.
