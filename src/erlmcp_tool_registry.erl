
-module(erlmcp_tool_registry).

-behaviour(gen_server).

-export([
    start_link/0,
    register_tool/1,
    unregister_tool/1,
    get_tool/1,
    list_tools/0,
    update_tool/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%%====================================================================
%% Public API
%%====================================================================

%% Start the locally registered tool registry.
start_link() ->
    gen_server:start_link(
        {local, ?MODULE},
        ?MODULE,
        [],
        []
    ).

%% Register a new tool.
register_tool(Tool) ->
    gen_server:call(?MODULE, {register_tool, Tool}).

%% Unregister a tool by name.
unregister_tool(Name) ->
    gen_server:call(?MODULE, {unregister_tool, Name}).

%% Retrieve the complete internal tool definition.
get_tool(Name) ->
    gen_server:call(?MODULE, {get_tool, Name}).

%% List public MCP tool definitions.
%% Internal handlers are never exposed.
list_tools() ->
    gen_server:call(?MODULE, list_tools).

%% Replace an existing tool definition.
update_tool(Tool) ->
    gen_server:call(?MODULE, {update_tool, Tool}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #{}}.

handle_call({register_tool, Tool}, _From, State) ->
    case validate_tool(Tool) of
        {ok, Name} ->
            case maps:is_key(Name, State) of
                true ->
                    {reply, {error, already_registered}, State};
                false ->
                    {reply, ok, State#{Name => Tool}}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({unregister_tool, Name}, _From, State) ->
    case valid_name(Name) of
        true ->
            case maps:is_key(Name, State) of
                true ->
                    {reply, ok, maps:remove(Name, State)};
                false ->
                    {reply, {error, not_found}, State}
            end;
        false ->
            {reply, {error, invalid_tool_name}, State}
    end;

handle_call({get_tool, Name}, _From, State) ->
    case valid_name(Name) of
        true ->
            case maps:find(Name, State) of
                {ok, Tool} ->
                    {reply, {ok, Tool}, State};
                error ->
                    {reply, {error, not_found}, State}
            end;
        false ->
            {reply, {error, invalid_tool_name}, State}
    end;

handle_call(list_tools, _From, State) ->
    Tools = [
        public_definition(Tool)
     || {_Name, Tool} <- lists:sort(maps:to_list(State))
    ],
    {reply, {ok, Tools}, State};

handle_call({update_tool, Tool}, _From, State) ->
    case validate_tool(Tool) of
        {ok, Name} ->
            case maps:is_key(Name, State) of
                true ->
                    {reply, ok, State#{Name => Tool}};
                false ->
                    {reply, {error, not_found}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal validation
%%====================================================================

validate_tool(Tool) when is_map(Tool) ->
    case maps:find(name, Tool) of
        {ok, Name} ->
            case valid_name(Name) of
                true ->
                    validate_tool_fields(Tool, Name);
                false ->
                    {error, invalid_tool_name}
            end;
        error ->
            {error, missing_tool_name}
    end;

validate_tool(_Tool) ->
    {error, invalid_tool_definition}.

validate_tool_fields(Tool, Name) ->
    case validate_description(Tool) of
        ok ->
            case validate_input_schema(Tool) of
                ok ->
                    case validate_handler(Tool) of
                        ok ->
                            {ok, Name};
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

validate_description(Tool) ->
    case maps:find(description, Tool) of
        error ->
            ok;
        {ok, Description}
          when is_binary(Description) ->
            ok;
        {ok, _Description} ->
            {error, invalid_tool_description}
    end.

validate_input_schema(Tool) ->
    case maps:find(input_schema, Tool) of
        {ok, #{<<"type">> := <<"object">>}} ->
            ok;
        {ok, _Schema} ->
            {error, invalid_input_schema};
        error ->
            {error, missing_input_schema}
    end.

validate_handler(Tool) ->
    case maps:find(handler, Tool) of
        {ok, Handler}
          when is_function(Handler, 1) orelse is_function(Handler, 2) ->
            ok;
        {ok, _Handler} ->
            {error, invalid_tool_handler};
        error ->
            {error, missing_tool_handler}
    end.

valid_name(Name) ->
    is_binary(Name) andalso byte_size(Name) > 0.

%%====================================================================
%% MCP public definition
%%====================================================================

%% Convert an internal tool definition into its MCP representation.
%% The Erlang handler remains private to the registry.
public_definition(Tool) ->
    Name = maps:get(name, Tool),
    InputSchema = maps:get(input_schema, Tool),

    Definition = #{
        <<"name">> => Name,
        <<"inputSchema">> => InputSchema
    },

    case maps:find(description, Tool) of
        {ok, Description} ->
            Definition#{<<"description">> => Description};
        error ->
            Definition
    end.
