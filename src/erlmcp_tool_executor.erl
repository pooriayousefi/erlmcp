
%%--------------------------------------------------------------------
%% Module: erlmcp_tool_executor
%%
%% Purpose:
%%   Executes tools registered in erlmcp_tool_registry.
%%
%% Responsibilities:
%%   - Retrieve tool definitions and invoke their handler functions.
%%   - Run each invocation in an independent monitored worker process.
%%   - Support concurrent tool execution.
%%   - Enforce per-call execution timeouts.
%%   - Convert handler exceptions and worker failures into error results.
%%
%% Architecture:
%%   The executor is a gen_server that coordinates tool invocations.
%%   It does not own tool definitions; those belong to
%%   erlmcp_tool_registry. Each tool handler runs outside the executor
%%   process so a slow or failing handler cannot block other calls.
%%
%% Result contract:
%%   Successful execution: {ok, HandlerResult}
%%   Failed execution:     {error, Reason}
%%--------------------------------------------------------------------

-module(erlmcp_tool_executor).

-behaviour(gen_server).

-export([
    start_link/0,
    execute_tool/2,
    execute_tool/3,
    execute_tool/4
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_TIMEOUT, 30000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

execute_tool(Name, Arguments) ->
    execute_tool(Name, Arguments, ?DEFAULT_TIMEOUT).

execute_tool(Name, Arguments, Timeout)
  when is_integer(Timeout), Timeout > 0 ->
    execute_tool(Name, Arguments, Timeout, #{});
execute_tool(_Name, _Arguments, _Timeout) ->
    {error, invalid_timeout}.

execute_tool(Name, Arguments, Timeout, Context)
  when is_integer(Timeout), Timeout > 0, is_map(Context) ->
    gen_server:call(
        ?MODULE,
        {execute_tool, Name, Arguments, Timeout, Context},
        Timeout + 5000
    );
execute_tool(_Name, _Arguments, _Timeout, _Context) ->
    {error, invalid_options}.

init([]) ->
    {ok, #{}}.

handle_call(
    {execute_tool, _Name, Arguments, _Timeout},
    _From,
    State
) when not is_map(Arguments) ->
    {reply, {error, invalid_arguments}, State};

handle_call(
    {execute_tool, Name, Arguments, Timeout, Context},
    From,
    State
) ->
    case lookup_handler(Name) of
        {ok, Handler} ->
            start_execution(
                Handler, Arguments, Context, Timeout, From, State
            );
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(
    {tool_result, Ref, Result},
    State
) ->
    case maps:take(Ref, State) of
        {Execution, NewState} ->
            cancel_execution(Execution),
            gen_server:reply(maps:get(from, Execution), Result),
            {noreply, NewState};
        error ->
            {noreply, State}
    end;

handle_info(
    {execution_timeout, Ref},
    State
) ->
    case maps:take(Ref, State) of
        {Execution, NewState} ->
            stop_worker(Execution),
            gen_server:reply(
                maps:get(from, Execution),
                {error, timeout}
            ),
            {noreply, NewState};
        error ->
            {noreply, State}
    end;

handle_info(
    {'DOWN', Monitor, process, _Pid, Reason},
    State
) ->
    case find_execution(Monitor, State) of
        {ok, Ref, Execution} ->
            cancel_timer(maps:get(timer, Execution)),
            gen_server:reply(
                maps:get(from, Execution),
                {error, {worker_down, Reason}}
            ),
            {noreply, maps:remove(Ref, State)};
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
        fun(_Ref, Execution) ->
            stop_worker(Execution),
            gen_server:reply(
                maps:get(from, Execution),
                {error, executor_stopped}
            )
        end,
        State
    ),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

lookup_handler(Name) ->
    try erlmcp_tool_registry:get_tool(Name) of
        {ok, Tool} ->
            case maps:find(handler, Tool) of
                {ok, Handler}
                        when is_function(Handler, 1) orelse
                             is_function(Handler, 2) ->
                    {ok, Handler};
                _ ->
                    {error, invalid_tool_handler}
            end;
        {error, Reason} ->
            {error, Reason};
        _ ->
            {error, invalid_tool_definition}
    catch
        exit:_Reason ->
            {error, registry_unavailable}
    end.

start_execution(Handler, Arguments, Context, Timeout, From, State) ->
    Ref = make_ref(),
    Parent = self(),

    {Pid, Monitor} = spawn_monitor(
        fun() ->
            Result = run_handler(Handler, Arguments, Context),
            Parent ! {tool_result, Ref, Result}
        end
    ),

    Timer = erlang:send_after(
        Timeout,
        self(),
        {execution_timeout, Ref}
    ),

    Execution = #{
        from => From,
        pid => Pid,
        monitor => Monitor,
        timer => Timer
    },

    {noreply, State#{Ref => Execution}}.

run_handler(Handler, Arguments, Context) ->
    try invoke_handler(Handler, Arguments, Context) of
        Result ->
            {ok, Result}
    catch
        Class:Reason ->
            {error, {execution_failed, Class, Reason}}
    end.

invoke_handler(Handler, Arguments, _Context)
        when is_function(Handler, 1) ->
    Handler(Arguments);
invoke_handler(Handler, Arguments, Context)
        when is_function(Handler, 2) ->
    Handler(Arguments, Context).

find_execution(Monitor, State) ->
    case lists:search(
        fun({_Ref, Execution}) ->
            maps:get(monitor, Execution) =:= Monitor
        end,
        maps:to_list(State)
    ) of
        {value, {Ref, Execution}} ->
            {ok, Ref, Execution};
        false ->
            error
    end.

cancel_execution(Execution) ->
    cancel_timer(maps:get(timer, Execution)),
    erlang:demonitor(maps:get(monitor, Execution), [flush]),
    ok.

stop_worker(Execution) ->
    cancel_timer(maps:get(timer, Execution)),
    Pid = maps:get(pid, Execution),
    Monitor = maps:get(monitor, Execution),
    exit(Pid, kill),
    erlang:demonitor(Monitor, [flush]),
    ok.

cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
