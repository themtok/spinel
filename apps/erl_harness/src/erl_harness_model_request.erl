-%% Runs one model request for a session.
%% Forwards text deltas, assembles streamed function calls, and reports the
%% completed assistant message or an error to the session.

module(erl_harness_model_request).
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Session, Ref, Request) ->
    gen_server:start_link(?MODULE, {Session, Ref, Request}, []).

init({Session, Ref, Request}) ->
    process_flag(trap_exit, true),
    Monitor = erlang:monitor(process, Session),
    {ok, #{session => Session, ref => Ref, monitor => Monitor, request => Request,
        text => [], calls => #{}, finish => undefined}, {continue, request}}.

handle_continue(request, #{request := Request} = State) ->
    case start_stream(Request, erl_harness_config:provider()) of
        {ok, Stream} -> {noreply, (maps:remove(request, State))#{stream => Stream}};
        {error, Reason} -> finish({error, Reason}, State)
    end.

start_stream(Request, #{url := Url, api_key := Key} = Provider) ->
    case uri_string:parse(Url) of
        #{host := <<"openrouter.ai">>} when Key =:= <<>> -> {error, missing_openrouter_api_key};
        _ -> erl_harness_openai:stream(Request, Provider)
    end.

handle_call(_, _, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(cancel, State) ->
    {stop, normal, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info({openai, Stream, {chunk, Chunk}}, #{stream := Stream} = State) ->
    case consume(Chunk, State) of
        {ok, Next} -> {noreply, Next};
        {error, Reason} -> finish({error, Reason}, State)
    end;
handle_info({openai, Stream, done}, #{stream := Stream} = State) ->
    finish(completion(State), State);
handle_info({openai, Stream, {error, Reason}}, #{stream := Stream} = State) ->
    finish({error, Reason}, State);
handle_info({'DOWN', Monitor, process, _, _}, #{monitor := Monitor} = State) ->
    {stop, normal, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, #{stream := Stream}) ->
    try erl_harness_openai:cancel(Stream)
    catch exit:_ -> ok
    end,
    ok;
terminate(_, _) ->
    ok.

consume(#{<<"choices">> := [Choice | _]}, State) when is_map(Choice) ->
    try
        Delta = maps:get(<<"delta">>, Choice, #{}),
        Text = piece(<<"content">>, Delta),
        ToolDeltas = case maps:get(<<"tool_calls">>, Delta, null) of
            null -> [];
            ValueList when is_list(ValueList) -> ValueList
        end,
        Calls = lists:foldl(fun add_call/2, maps:get(calls, State), ToolDeltas),
        Finish = case maps:get(<<"finish_reason">>, Choice, null) of
            null -> maps:get(finish, State);
            Value -> Value
        end,
        case Text of
            <<>> -> ok;
            _ -> notify({delta, Text}, State)
        end,
        {ok, State#{calls := Calls, text := [Text | maps:get(text, State)], finish := Finish}}
    catch error:_ -> {error, invalid_completion_delta}
    end;
consume(_, State) ->
    {ok, State}.

piece(Key, Map) ->
    case maps:get(Key, Map, null) of
        null -> <<>>;
        Binary when is_binary(Binary) -> Binary
    end.

add_call(#{<<"index">> := Index} = Delta, Calls) when is_integer(Index), Index >= 0 ->
    Function = maps:get(<<"function">>, Delta, #{}),
    {Id, Name, Args} = maps:get(Index, Calls, {<<>>, <<>>, []}),
    IdPart = piece(<<"id">>, Delta),
    NamePart = piece(<<"name">>, Function),
    Calls#{Index => {<<Id/binary, IdPart/binary>>, <<Name/binary, NamePart/binary>>,
        [piece(<<"arguments">>, Function) | Args]}}.

completion(#{finish := Finish, text := Text, calls := Calls}) ->
    Ordered = [Call || {_, Call} <- lists:sort(maps:to_list(Calls))],
    case {Finish, Ordered} of
        {<<"stop">>, []} -> {ok, assistant(Text), []};
        {<<"tool_calls">>, [_ | _]} -> tool_completion(Text, Ordered);
        _ -> {error, {completion_stopped, Finish}}
    end.

tool_completion(Text, Calls) ->
    Ids = [Id || {Id, _, _} <- Calls],
    case length(lists:usort(Ids)) =:= length(Calls) andalso
        lists:all(fun({Id, Name, _}) -> Id =/= <<>> andalso Name =/= <<>> end, Calls) of
        true ->
            Tools = [#{id => Id, type => <<"function">>, function => #{
                name => Name, arguments => iolist_to_binary(lists:reverse(Args))}}
                || {Id, Name, Args} <- Calls],
            {ok, (assistant(Text))#{tool_calls => Tools}, Tools};
        false -> {error, invalid_tool_calls}
    end.

assistant(Text) ->
    #{role => <<"assistant">>, content => iolist_to_binary(lists:reverse(Text))}.

finish(Result, State) ->
    notify({finished, Result}, State),
    {stop, normal, State}.

notify(Event, #{session := Session, ref := Ref}) ->
    Session ! {model_request, Ref, Event}.
