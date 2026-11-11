-%% Owns one conversation and its in-memory transcript.
%% The state machine alternates model requests with tool execution, records
%% results, and handles cancellation, timeouts, and worker exits.

module(erl_harness_session).
-behaviour(gen_statem).

-export([start_link/2, submit/2, cancel/1, transcript/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

-define(MODEL_TIMEOUT, 120000).
-define(TOOL_TIMEOUT, 45000).
-define(MAX_TOOL_CALLS, 32).

start_link(Owner, Workspace) ->
    gen_statem:start_link(?MODULE, {Owner, Workspace}, []).

submit(Pid, Text) ->
    gen_statem:call(Pid, {submit, Text}).

cancel(Pid) ->
    gen_statem:call(Pid, cancel).

transcript(Pid) ->
    gen_statem:call(Pid, transcript).

callback_mode() -> handle_event_function.

init({Owner, Workspace}) ->
    process_flag(trap_exit, true),
    Settings = erl_harness_config:get(),
    {ok, idle, #{owner => Owner, owner_monitor => erlang:monitor(process, Owner),
        workspace => Workspace, settings => Settings, history => [], active => undefined}}.

handle_event({call, From}, {submit, Text}, idle, Data)
    when is_binary(Text), byte_size(Text) > 0 ->
    Turn = make_ref(),
    #{settings := #{native_tools := Native}} = Data,
    Active = #{id => Turn, messages => [#{role => <<"user">>, content => Text}],
        model_calls => 0, catalog => erl_harness_tool:catalog(Native), pending => undefined},
    {next_state, awaiting_model, Data#{active := Active},
        [{reply, From, {ok, Turn}}, {next_event, internal, model}]};
handle_event({call, From}, {submit, _}, idle, _) ->
    {keep_state_and_data, [{reply, From, {error, empty_prompt}}]};
handle_event({call, From}, {submit, _}, _, _) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
handle_event({call, From}, cancel, idle, _) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, cancel, State, Data) ->
    stop_pending(State, Data),
    finish(cancelled, Data, [{reply, From, ok}]);
handle_event({call, From}, transcript, _, #{history := History, active := Active}) ->
    Current = case Active of
        undefined -> undefined;
        #{messages := Messages} -> lists:reverse(Messages)
    end,
    {keep_state_and_data, [{reply, From, #{turns => lists:reverse(History), active => Current}}]};

handle_event(internal, model, awaiting_model, Data) ->
    start_model(Data);
handle_event(internal, tool, awaiting_tools, Data) ->
    start_tool(Data);

handle_event(info, {model_request, Ref, {delta, Text}}, awaiting_model,
    #{active := #{pending := #{ref := Ref}}} = Data) ->
    emit({delta, Text}, Data),
    keep_state_and_data;
handle_event(info, {model_request, Ref, {finished, Result}}, awaiting_model,
    #{active := #{pending := #{ref := Ref}}} = Data) ->
    handle_model_result(Result, clear_pending(Data));
handle_event(info, {tool_exec, Ref, Result}, awaiting_tools,
    #{active := #{pending := #{ref := Ref}, tools := [Call | _]}} = Data) ->
    record_tool(Call, Result, clear_pending(Data));
handle_event(info, {'DOWN', Monitor, process, _, _}, _, #{owner_monitor := Monitor} = Data) ->
    {stop, normal, Data};
handle_event(info, {'DOWN', Monitor, process, _, Reason}, awaiting_model,
    #{active := #{pending := #{monitor := Monitor}}} = Data) ->
    finish({error, {request_worker_exited, Reason}}, clear_pending(Data), []);
handle_event(info, {'DOWN', Monitor, process, _, Reason}, awaiting_tools,
    #{active := #{pending := #{monitor := Monitor}, tools := [Call | _]}} = Data) ->
    record_tool(Call, {error, {tool_worker_exited, Reason}}, clear_pending(Data));

handle_event(state_timeout, {timeout, Ref}, awaiting_tools,
    #{active := #{pending := #{ref := Ref}, tools := [Call | _]}} = Data) ->
    stop_pending(awaiting_tools, Data),
    record_tool(Call, {error, tool_timeout}, clear_pending(Data));
handle_event(state_timeout, {timeout, Ref}, State,
    #{active := #{pending := #{ref := Ref}}} = Data) ->
    stop_pending(State, Data),
    finish({error, {timeout, State}}, clear_pending(Data), []);
handle_event(_, _, _, _) ->
    keep_state_and_data.

start_model(#{active := #{model_calls := Calls}, settings := #{max_model_calls := Max}} = Data)
    when Calls >= Max ->
    finish({error, model_call_limit}, Data, []);
start_model(#{active := Active, history := History, settings := Settings} = Data) ->
    #{model := Model, context_budget_bytes := Budget} = Settings,
    #{messages := Messages, catalog := Catalog, model_calls := Calls} = Active,
    Completed = [Turn || #{outcome := done, messages := Turn} <- History],
    case erl_harness_context:request(Model, Completed, lists:reverse(Messages),
        erl_harness_tool:schemas(Catalog), Budget) of
        {ok, Request} ->
            start_worker(erl_harness_requests_sup, erl_harness_model_request, [Request],
                ?MODEL_TIMEOUT, Data#{active := Active#{model_calls := Calls + 1}});
        {error, Reason} ->
            finish({error, Reason}, Data, [])
    end.

handle_model_result({ok, Message, []}, Data) ->
    finish(done, append(Message, Data), []);
handle_model_result({ok, Message, Tools}, Data) when length(Tools) =< ?MAX_TOOL_CALLS ->
    #{active := Active} = Next = append(Message, Data),
    {next_state, awaiting_tools, Next#{active := Active#{tools => Tools}},
        [{next_event, internal, tool}]};
handle_model_result({ok, _, _}, Data) ->
    finish({error, tool_call_limit}, Data, []);
handle_model_result({error, Reason}, Data) ->
    finish({error, Reason}, Data, []).

start_tool(#{active := #{tools := []}} = Data) ->
    {next_state, awaiting_model, Data, [{next_event, internal, model}]};
start_tool(#{active := #{tools := [Call | _], catalog := Catalog}, workspace := Workspace} = Data) ->
    case erl_harness_tool:resolve(Call, Catalog) of
        {ok, Execution} ->
            emit({tool, name(Call), running}, Data),
            start_worker(erl_harness_tools_sup, erl_harness_tool_exec, [Execution, Workspace],
                ?TOOL_TIMEOUT, Data);
        {error, _} = Error ->
            record_tool(Call, Error, Data)
    end.

start_worker(Supervisor, Module, Args, Timeout, #{active := Active} = Data) ->
    Ref = make_ref(),
    Started = try erl_harness_pool:start_child(Supervisor, Module, [self(), Ref | Args])
        catch exit:StartReason -> {error, StartReason}
        end,
    case Started of
        {ok, Pid} ->
            Pending = #{pid => Pid, monitor => erlang:monitor(process, Pid), ref => Ref},
            {keep_state, Data#{active := Active#{pending := Pending}},
                [{state_timeout, Timeout, {timeout, Ref}}]};
        {error, Reason} ->
            finish({error, {cannot_start_worker, Module, Reason}}, Data, [])
    end.

record_tool(#{id := Id} = Call, Result, Data) ->
    {Content, Status} = encode_result(Result),
    emit({tool, name(Call), Status}, Data),
    Message = #{role => <<"tool">>, tool_call_id => Id, content => Content},
    #{active := #{tools := [_ | Rest]} = Active} = Next = append(Message, Data),
    {keep_state, Next#{active := Active#{tools := Rest}}, [{next_event, internal, tool}]}.

encode_result({ok, Value}) ->
    try iolist_to_binary(json:encode(Value)) of
        Binary when byte_size(Binary) =< 24576 -> {Binary, done};
        _ -> encode_result({error, tool_output_too_large})
    catch error:_ -> encode_result({error, invalid_tool_result})
    end;
encode_result({error, Reason}) ->
    Text = unicode:characters_to_binary(io_lib:format("~P", [Reason, 6])),
    {iolist_to_binary(json:encode(#{error => Text})), failed};
encode_result(_) ->
    encode_result({error, invalid_tool_result}).

name(#{function := #{name := Name}}) -> Name.

append(Message, #{active := #{messages := Messages} = Active} = Data) ->
    Data#{active := Active#{messages := [Message | Messages]}}.

clear_pending(#{active := #{pending := #{monitor := Monitor}} = Active} = Data) ->
    erlang:demonitor(Monitor, [flush]),
    Data#{active := Active#{pending := undefined}}.

stop_pending(awaiting_model, #{active := #{pending := #{pid := Pid}}}) ->
    gen_server:cast(Pid, cancel);
stop_pending(awaiting_tools, #{active := #{pending := #{pid := Pid}}}) ->
    exit(Pid, shutdown);
stop_pending(_, _) ->
    ok.

finish(Outcome, #{active := Active, history := History} = Data, Actions) ->
    #{id := Id, messages := Messages, pending := Pending} = Active,
    case Pending of
        #{monitor := Monitor} -> erlang:demonitor(Monitor, [flush]);
        undefined -> ok
    end,
    emit(Outcome, Data),
    Turn = #{id => Id, outcome => Outcome, messages => lists:reverse(Messages)},
    {next_state, idle, Data#{active := undefined, history := [Turn | History]}, Actions}.

emit(Event, #{owner := Owner, active := #{id := Id}}) ->
    Owner ! {harness, Id, Event}.

terminate(_, State, Data) ->
    stop_pending(State, Data).
