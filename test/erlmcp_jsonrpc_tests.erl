
-module(erlmcp_jsonrpc_tests).

-include_lib("eunit/include/eunit.hrl").

%% ------------------------------------------------------------------
%% Construction
%% ------------------------------------------------------------------

request_construction_test() ->
    Message = erlmcp_jsonrpc:request(
        1,
        <<"tools/list">>,
        #{}
    ),

    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Message)),
    ?assertEqual(1, maps:get(<<"id">>, Message)),
    ?assertEqual(<<"tools/list">>, maps:get(<<"method">>, Message)),
    ?assertEqual(#{}, maps:get(<<"params">>, Message)).

notification_construction_test() ->
    Message = erlmcp_jsonrpc:notification(
        <<"notifications/cancelled">>,
        #{}
    ),

    ?assertEqual(false, maps:is_key(<<"id">>, Message)),
    ?assertEqual(<<"notifications/cancelled">>,
                 maps:get(<<"method">>, Message)).

response_construction_test() ->
    Result = #{<<"tools">> => []},
    Message = erlmcp_jsonrpc:response(1, Result),

    ?assertEqual(1, maps:get(<<"id">>, Message)),
    ?assertEqual(Result, maps:get(<<"result">>, Message)).

error_construction_test() ->
    Message = erlmcp_jsonrpc:error(
        1,
        -32601,
        <<"Method not found">>,
        undefined
    ),

    ErrorObject = maps:get(<<"error">>, Message),

    ?assertEqual(-32601, maps:get(<<"code">>, ErrorObject)),
    ?assertEqual(<<"Method not found">>,
                 maps:get(<<"message">>, ErrorObject)),
    ?assertEqual(false, maps:is_key(<<"data">>, ErrorObject)).

error_with_data_construction_test() ->
    Message = erlmcp_jsonrpc:error(
        1,
        -32602,
        <<"Invalid params">>,
        #{<<"field">> => <<"name">>}
    ),

    ErrorObject = maps:get(<<"error">>, Message),

    ?assert(maps:is_key(<<"data">>, ErrorObject)).

%% ------------------------------------------------------------------
%% Valid messages
%% ------------------------------------------------------------------

valid_request_test() ->
    Message = erlmcp_jsonrpc:request(
        1,
        <<"tools/call">>,
        #{<<"name">> => <<"hello">>}
    ),

    ?assertEqual({ok, request}, erlmcp_jsonrpc:validate(Message)),
    ?assert(erlmcp_jsonrpc:is_request(Message)).

valid_notification_test() ->
    Message = erlmcp_jsonrpc:notification(
        <<"notifications/cancelled">>,
        #{}
    ),

    ?assertEqual(
        {ok, notification},
        erlmcp_jsonrpc:validate(Message)
    ),

    ?assert(erlmcp_jsonrpc:is_notification(Message)).

valid_response_test() ->
    Message = erlmcp_jsonrpc:response(1, #{}),

    ?assertEqual({ok, response}, erlmcp_jsonrpc:validate(Message)),
    ?assert(erlmcp_jsonrpc:is_response(Message)).

valid_error_response_test() ->
    Message = erlmcp_jsonrpc:error(
        1,
        -32601,
        <<"Method not found">>,
        undefined
    ),

    ?assertEqual(
        {ok, error_response},
        erlmcp_jsonrpc:validate(Message)
    ),

    ?assert(erlmcp_jsonrpc:is_error(Message)).

valid_string_id_test() ->
    Message = erlmcp_jsonrpc:request(
        <<"request-1">>,
        <<"tools/list">>,
        #{}
    ),

    ?assert(erlmcp_jsonrpc:is_request(Message)).

valid_array_params_test() ->
    Message = erlmcp_jsonrpc:request(
        1,
        <<"example">>,
        [<<"value">>]
    ),

    ?assert(erlmcp_jsonrpc:is_request(Message)).

params_omitted_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"example">>
    },

    ?assert(erlmcp_jsonrpc:is_request(Message)).

%% ------------------------------------------------------------------
%% Invalid messages
%% ------------------------------------------------------------------

non_map_message_test() ->
    ?assertEqual(
        {error, invalid_message},
        erlmcp_jsonrpc:validate([])
    ).

invalid_version_test() ->
    Message = #{
        <<"jsonrpc">> => <<"1.0">>,
        <<"id">> => 1,
        <<"method">> => <<"example">>
    },

    ?assertEqual(
        {error, invalid_jsonrpc_version},
        erlmcp_jsonrpc:validate(Message)
    ).

missing_method_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1
    },

    ?assertEqual(
        {error, missing_message_field},
        erlmcp_jsonrpc:validate(Message)
    ).

invalid_method_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => 42
    },

    ?assertEqual(
        {error, invalid_method},
        erlmcp_jsonrpc:validate(Message)
    ).

empty_method_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<>>
    },

    ?assertEqual(
        {error, invalid_method},
        erlmcp_jsonrpc:validate(Message)
    ).

invalid_params_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"example">>,
        <<"params">> => <<"invalid">>
    },

    ?assertEqual(
        {error, invalid_params},
        erlmcp_jsonrpc:validate(Message)
    ).

invalid_request_id_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => null,
        <<"method">> => <<"example">>
    },

    ?assertEqual(
        {error, invalid_request_id},
        erlmcp_jsonrpc:validate(Message)
    ).

response_without_id_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"result">> => #{}
    },

    ?assertEqual(
        {error, missing_response_id},
        erlmcp_jsonrpc:validate(Message)
    ).

conflicting_response_fields_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"result">> => #{},
        <<"error">> => #{}
    },

    ?assertEqual(
        {error, conflicting_message_fields},
        erlmcp_jsonrpc:validate(Message)
    ).

invalid_error_object_test() ->
    Message = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"error">> => #{
            <<"code">> => <<"wrong">>,
            <<"message">> => <<"Failure">>
        }
    },

    ?assertEqual(
        {error, invalid_error_response},
        erlmcp_jsonrpc:validate(Message)
    ).

null_error_id_test() ->
    Message = erlmcp_jsonrpc:error(
        null,
        -32700,
        <<"Parse error">>,
        undefined
    ),

    ?assert(erlmcp_jsonrpc:is_error(Message)).
