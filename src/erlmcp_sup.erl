%%--------------------------------------------------------------------
%% @doc
%% Top-level supervisor for the erlmcp application.
%%
%% Owns the long-lived processes required by the MCP server side:
%%   - erlmcp_tool_registry
%%   - erlmcp_tool_executor
%%
%% Client connections and transports are transient and are started
%% by the application user.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    Children = [
        #{
            id => erlmcp_tool_registry,
            start => {erlmcp_tool_registry, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erlmcp_tool_registry]
        },
        #{
            id => erlmcp_tool_executor,
            start => {erlmcp_tool_executor, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erlmcp_tool_executor]
        }
    ],

    {ok, {SupFlags, Children}}.
