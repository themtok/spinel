-%% Keeps the tool catalogs published by connected MCP clients.
%% Combines them for tool discovery and removes a client's catalog when it exits.

module(erl_harness_mcp).
-behaviour(gen_server).

-export([start_link/0, catalog/0, publish/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

catalog() ->
    gen_server:call(?MODULE, catalog).

publish(Client, Tools) ->
    gen_server:cast(?MODULE, {catalog, Client, Tools}).

init([]) ->
    {ok, #{}}.

handle_call(catalog, _, Clients) ->
    {reply, lists:append([Tools || {_, Tools} <- maps:values(Clients)]), Clients}.

handle_cast({catalog, Pid, Tools}, Clients) ->
    Ref = case maps:find(Pid, Clients) of
        {ok, {Existing, _}} -> Existing;
        error -> erlang:monitor(process, Pid)
    end,
    {noreply, Clients#{Pid => {Ref, Tools}}}.

handle_info({'DOWN', _, process, Pid, _}, Clients) ->
    {noreply, maps:remove(Pid, Clients)};
handle_info(_, Clients) ->
    {noreply, Clients}.
