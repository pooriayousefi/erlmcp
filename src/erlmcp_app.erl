%%--------------------------------------------------------------------
%% @doc
%% OTP application callback module for erlmcp.
%%
%% Starts the supervision tree that owns the tool registry and
%% tool executor. Transports and client connections are started
%% on demand by the user.
%% @end
%%--------------------------------------------------------------------
-module(erlmcp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    erlmcp_sup:start_link().

stop(_State) ->
    ok.
