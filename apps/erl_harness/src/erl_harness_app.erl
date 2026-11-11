-%% OTP entry point for the harness application.
%% Starts the root supervisor, which owns the lifetime of the runtime processes.

module(erl_harness_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    erl_harness_sup:start_link().

stop(_State) ->
    ok.
