-%% Supervises the MCP catalog manager and one client per configured endpoint.
%% Starts the manager first so clients can publish their discovered tools.

module(erl_harness_mcp_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    #{mcp_servers := Servers} = erl_harness_config:get(),
    Manager = #{id => erl_harness_mcp, start => {erl_harness_mcp, start_link, []}},
    Clients = [#{id => {client, maps:get(name, Server)},
        start => {erl_harness_mcp_client, start_link, [Server]}} || Server <- Servers],
    {ok, {#{strategy => rest_for_one}, [Manager | Clients]}}.
