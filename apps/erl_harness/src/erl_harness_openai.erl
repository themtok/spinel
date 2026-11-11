-%% Shared HTTP transport for OpenAI-compatible Chat Completions.
%% Starts asynchronous requests, decodes server-sent events, and sends stream
%% updates to their owners. Cancels requests when the owner exits.

module(erl_harness_openai).
-behaviour(gen_server).

-export([start_link/0, stream/1, stream/2, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(stream, {
    owner,
    monitor,
    decoder = erl_harness_sse:new()
}).

-record(state, {requests = #{}, monitors = #{}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The caller receives {openai, Ref, {chunk, Map} | done | {error, Reason}}.
-spec stream(map()) -> {ok, reference()} | {error, term()}.
stream(Request) ->
    BaseUrl = application:get_env(erl_harness, openai_base_url,
        os:getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")),
    Url = string:trim(unicode:characters_to_list(BaseUrl), trailing, "/")
        ++ "/chat/completions",
    stream(Request, #{url => Url, api_key => os:getenv("OPENAI_API_KEY", "")}).

stream(Request, Endpoint) ->
    gen_server:call(?MODULE, {stream, Request, Endpoint}).

-spec cancel(reference()) -> ok | {error, not_found | not_owner}.
cancel(Ref) ->
    gen_server:call(?MODULE, {cancel, Ref}).

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({stream, Request, Endpoint}, {Owner, _}, State) ->
    case start_request(Request, Endpoint) of
        {ok, Ref} ->
            Monitor = erlang:monitor(process, Owner),
            Stream = #stream{owner = Owner, monitor = Monitor},
            {reply, {ok, Ref}, State#state{
                requests = maps:put(Ref, Stream, State#state.requests),
                monitors = maps:put(Monitor, Ref, State#state.monitors)
            }};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({cancel, Ref}, {Owner, _}, State) ->
    case maps:find(Ref, State#state.requests) of
        {ok, #stream{owner = Owner} = Stream} ->
            {reply, ok, finish(Ref, Stream, {error, cancelled}, State)};
        {ok, _} ->
            {reply, {error, not_owner}, State};
        error ->
            {reply, {error, not_found}, State}
    end.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({http, Response}, State) ->
    Ref = element(1, Response),
    case maps:find(Ref, State#state.requests) of
        {ok, Stream} -> {noreply, handle_response(Response, Ref, Stream, State)};
        error -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case maps:find(Monitor, State#state.monitors) of
        {ok, Ref} ->
            Stream = maps:get(Ref, State#state.requests),
            {noreply, forget(Ref, Stream, State)};
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{requests = Requests}) ->
    maps:foreach(fun(Ref, #stream{owner = Owner}) ->
        httpc:cancel_request(Ref),
        Owner ! {openai, Ref, {error, shutdown}}
    end, Requests),
    ok.

start_request(Request, Endpoint) when is_map(Request) ->
    Payload = (maps:remove(stream, Request))#{<<"stream">> => true},
    case encode_request(Payload) of
        {ok, Body} -> post(Body, Endpoint);
        {error, _} = Error -> Error
    end;
start_request(_Request, _Endpoint) ->
    {error, invalid_request}.

encode_request(Payload) ->
    try {ok, json:encode(Payload)}
    catch error:_ -> {error, invalid_request}
    end.

post(Body, #{url := Endpoint, api_key := Key}) ->
    Url = unicode:characters_to_list(Endpoint),
    Headers = [{"accept", "text/event-stream"} | authorization(Key)],
    HttpOptions = erl_harness_config:http_options(Url),
    httpc:request(post, {Url, Headers, "application/json", Body},
        HttpOptions, [{sync, false}, {stream, self}]).

authorization(Key) ->
    case unicode:characters_to_list(Key) of
        "" -> [];
        Value -> [{"authorization", "Bearer " ++ Value}]
    end.

handle_response({_Ref, stream_start, Headers}, Ref, Stream, State) ->
    ContentType = proplists:get_value("content-type", Headers, ""),
    MediaType = hd(string:split(string:lowercase(ContentType), ";")),
    case string:trim(MediaType) of
        "text/event-stream" -> State;
        _ -> finish(Ref, Stream, {error, {unexpected_content_type, ContentType}}, State)
    end;
handle_response({_Ref, stream, Bytes}, Ref, Stream, State) ->
    {Events, Decoder} = erl_harness_sse:feed(Bytes, Stream#stream.decoder),
    case forward(Events, Ref, Stream#stream.owner) of
        more ->
            State#state{requests = maps:put(Ref, Stream#stream{decoder = Decoder},
                State#state.requests)};
        Terminal ->
            finish(Ref, Stream, Terminal, State)
    end;
handle_response({_Ref, stream_end, _Headers}, Ref, Stream, State) ->
    finish(Ref, Stream, {error, incomplete_stream}, State);
handle_response({_Ref, {{_Version, Status, _Phrase}, _Headers, Body}}, Ref, Stream, State) ->
    finish(Ref, Stream, {error, {http_status, Status, Body}}, State);
handle_response({_Ref, {error, Reason}}, Ref, Stream, State) ->
    finish(Ref, Stream, {error, {transport, Reason}}, State).

forward([], _Ref, _Owner) ->
    more;
forward([<<"[DONE]">> | _], _Ref, _Owner) ->
    done;
forward([Data | Rest], Ref, Owner) ->
    case decode_event(Data) of
        {ok, Chunk} ->
            Owner ! {openai, Ref, {chunk, Chunk}},
            forward(Rest, Ref, Owner);
        {error, _} = Error ->
            Error
    end.

decode_event(Data) ->
    try json:decode(Data) of
        #{<<"error">> := Error} -> {error, {provider, Error}};
        Chunk when is_map(Chunk) -> {ok, Chunk};
        _ -> {error, invalid_stream_event}
    catch error:_ -> {error, invalid_stream_event}
    end.

finish(Ref, #stream{owner = Owner} = Stream, Event, State) ->
    NewState = forget(Ref, Stream, State),
    Owner ! {openai, Ref, Event},
    NewState.

forget(Ref, #stream{monitor = Monitor}, State) ->
    httpc:cancel_request(Ref),
    erlang:demonitor(Monitor, [flush]),
    State#state{
        requests = maps:remove(Ref, State#state.requests),
        monitors = maps:remove(Monitor, State#state.monitors)
    }.
