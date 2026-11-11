-%% Runs one resolved tool call in a temporary supervised process.
%% Converts execution exceptions to error results and sends the result back
%% with the session's call reference.

module(erl_harness_tool_exec).
-export([start_link/4, init/4]).

start_link(Session, Ref, Execution, Workspace) ->
    proc_lib:start_link(?MODULE, init, [Session, Ref, Execution, Workspace]).

init(Session, Ref, Execution, Workspace) ->
    proc_lib:init_ack({ok, self()}),
    Result = try erl_harness_tool:execute(Execution, Workspace)
        catch Class:Reason -> {error, {Class, Reason}}
        end,
    Session ! {tool_exec, Ref, Result},
    ok.
