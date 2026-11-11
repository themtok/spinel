-%% Reusable dynamic supervisor for sessions, model requests, and tool calls.
%% Starts children on demand and marks them temporary so OTP does not replay work.

module(erl_harness_pool).
-behaviour(supervisor).

-export([start_link/1, start_child/3, init/1]).

start_link(Name) ->
    supervisor:start_link({local, Name}, ?MODULE, []).

start_child(Supervisor, Module, Arguments) ->
    supervisor:start_child(Supervisor, #{
        id => make_ref(),
        start => {Module, start_link, Arguments},
        restart => temporary
    }).

init([]) ->
    {ok, {#{strategy => one_for_one}, []}}.
