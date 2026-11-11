-%% Legacy tests for the starter greeter.
%% Checks its greeting and expects the root supervisor to restart its worker.

module(erl_harness_greeter_tests).

-include_lib("eunit/include/eunit.hrl").

greeter_test_() ->
    {setup,
        fun start_app/0,
        fun stop_app/1,
        [
            fun returns_greeting/0,
            fun supervisor_restarts_worker/0
        ]}.

start_app() ->
    {ok, StartedApps} = application:ensure_all_started(erl_harness),
    StartedApps.

stop_app(StartedApps) ->
    lists:foreach(fun application:stop/1, lists:reverse(StartedApps)).

returns_greeting() ->
    ?assertEqual(<<"Hello, world!">>, erl_harness_greeter:greeting()).

supervisor_restarts_worker() ->
    OldWorker = whereis(erl_harness_greeter),
    exit(OldWorker, kill),
    Deadline = erlang:monotonic_time(millisecond) + 2000,
    await_replacement(OldWorker, Deadline),
    ?assertEqual(<<"Hello, world!">>, erl_harness_greeter:greeting()).

await_replacement(OldWorker, Deadline) ->
    case whereis(erl_harness_greeter) of
        Pid when is_pid(Pid), Pid =/= OldWorker ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(10),
                    await_replacement(OldWorker, Deadline);
                false ->
                    error(greeter_restart_timeout)
            end
    end.
