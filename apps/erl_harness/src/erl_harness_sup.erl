-%% Root of the harness supervision tree.
%% Starts configuration, HTTP transport, MCP supervision, dynamic worker pools,
%% and the session controller.

module(erl_harness_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        worker(erl_harness_config),
        worker(erl_harness_openai),
        pool(erl_harness_requests_sup),
        pool(erl_harness_tools_sup),
        #{id => erl_harness_mcp_sup, start => {erl_harness_mcp_sup, start_link, []},
            type => supervisor},
        pool(erl_harness_session_sup),
        worker(erl_harness_controller)
    ],
    {ok, {#{strategy => one_for_one}, Children}}.

worker(Module) ->
    #{id => Module, start => {Module, start_link, []}}.

pool(Name) ->
    #{id => Name, start => {erl_harness_pool, start_link, [Name]},
        type => supervisor, modules => [erl_harness_pool]}.
