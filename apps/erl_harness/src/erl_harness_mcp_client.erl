-%% Manages one Streamable HTTP MCP connection.
%% Negotiates the session, discovers and allowlists tools, sends JSON-RPC tool
%% calls, and reconnects when a server session expires.

module(erl_harness_mcp_client).
-behaviour(gen_server).

-export([start_link/1, call_tool/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(VERSION, <<"2025-11-25">>).

start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

call_tool(Pid, Name, Args) ->
    case gen_server:call(Pid, endpoint) of
        {ok, Endpoint} ->
            case rpc(Endpoint, <<"tools/call">>, #{name => Name, arguments => Args}) of
                {ok, #{<<"isError">> := true} = Result, _} -> {error, {mcp_tool, Result}};
                {ok, Result, _} -> {ok, Result};
                {error, {http_status, 404}} = Error ->
                    gen_server:cast(Pid, {expired, Endpoint}),
                    Error;
                Error -> Error
            end;
        Error -> Error
    end.

init(Config) ->
    self() ! connect,
    {ok, #{config => Config, endpoint => undefined}}.

handle_call(endpoint, _, #{endpoint := Endpoint} = State) when is_map(Endpoint) ->
    {reply, {ok, Endpoint}, State};
handle_call(endpoint, _, State) ->
    {reply, {error, mcp_unavailable}, State}.

handle_cast({expired, Endpoint}, #{endpoint := Endpoint} = State) ->
    erl_harness_mcp:publish(self(), []),
    self() ! connect,
    {noreply, State#{endpoint := undefined}};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(connect, #{config := Config, endpoint := undefined} = State) ->
    case connect(Config) of
        {ok, Endpoint, Tools} ->
            erl_harness_mcp:publish(self(), Tools),
            {noreply, State#{endpoint := Endpoint}};
        {error, _} ->
            erlang:send_after(10000, self(), connect),
            {noreply, State}
    end;
handle_info(_, State) ->
    {noreply, State}.

connect(#{url := Url} = Config) ->
    Endpoint = #{url => binary_to_list(Url), headers => auth_headers(Config)},
    Params = #{protocolVersion => ?VERSION, capabilities => #{},
        clientInfo => #{name => <<"erl_harness">>, version => <<"0.1.0">>}},
    case rpc(Endpoint, <<"initialize">>, Params) of
        {ok, #{<<"protocolVersion">> := Version}, Headers}
            when Version =:= ?VERSION; Version =:= <<"2025-06-18">>;
                 Version =:= <<"2025-03-26">> ->
            Ready = session_endpoint(Endpoint, Version, Headers),
            case post(Ready, #{jsonrpc => <<"2.0">>, method => <<"notifications/initialized">>}) of
                {ok, _, _} ->
                    case list_tools(Ready, #{}, 20, []) of
                        {ok, Tools} -> {ok, Ready, allowed_tools(Config, Tools)};
                        Error -> Error
                    end;
                Error -> Error
            end;
        {ok, _, _} -> {error, unsupported_mcp_version};
        Error -> Error
    end.

session_endpoint(#{headers := Base} = Endpoint, Version, Headers) ->
    Session = case proplists:get_value("mcp-session-id", Headers) of
        undefined -> [];
        Id -> [{"mcp-session-id", Id}]
    end,
    Endpoint#{headers := [{"mcp-protocol-version", binary_to_list(Version)} | Session ++ Base]}.

auth_headers(Config) ->
    case maps:get(api_key_env, Config, undefined) of
        undefined -> [];
        Variable ->
            case os:getenv(Variable, "") of
                "" -> [];
                Key -> [{"authorization", "Bearer " ++ Key}]
            end
    end.

list_tools(_, _, 0, _) ->
    {error, too_many_mcp_tool_pages};
list_tools(Endpoint, Params, Pages, Acc) ->
    case rpc(Endpoint, <<"tools/list">>, Params) of
        {ok, #{<<"tools">> := Tools, <<"nextCursor">> := Cursor}, _}
            when is_list(Tools), is_binary(Cursor) ->
            list_tools(Endpoint, #{cursor => Cursor}, Pages - 1, [Tools | Acc]);
        {ok, #{<<"tools">> := Tools}, _} when is_list(Tools) ->
            {ok, lists:append(lists:reverse([Tools | Acc]))};
        {ok, _, _} -> {error, invalid_mcp_tool_list};
        Error -> Error
    end.

allowed_tools(#{name := Prefix, allow := Allow}, Tools) ->
    [{Name, {#{name => Name, description => Desc, parameters => Schema},
        {mcp, self(), Remote}}} ||
        #{<<"name">> := Remote, <<"inputSchema">> := Schema} = Tool <- Tools,
        is_binary(Remote), is_map(Schema), lists:member(Remote, Allow),
        Name <- [<<Prefix/binary, "__", Remote/binary>>],
        re:run(Name, <<"^[A-Za-z0-9_-]{1,64}$">>, [{capture, none}]) =:= match,
        Desc <- [maps:get(<<"description">>, Tool, Remote)], is_binary(Desc)].

rpc(Endpoint, Method, Params) ->
    Id = erlang:unique_integer([positive]),
    Message = #{jsonrpc => <<"2.0">>, id => Id, method => Method, params => Params},
    case post(Endpoint, Message) of
        {ok, Headers, Body} ->
            case decode_response(Id, Headers, Body) of
                #{<<"result">> := Result} -> {ok, Result, Headers};
                #{<<"error">> := Error} -> {error, {mcp_rpc, Error}};
                _ -> {error, invalid_mcp_response}
            end;
        Error -> Error
    end.

post(#{url := Url, headers := Base}, Message) ->
    Headers = [{"accept", "application/json, text/event-stream"} | Base],
    Request = {Url, Headers, "application/json", json:encode(Message)},
    case httpc:request(post, Request, erl_harness_config:http_options(Url), [{body_format, binary}]) of
        {ok, {{_, Status, _}, ResponseHeaders, Body}} when Status >= 200, Status < 300 ->
            {ok, ResponseHeaders, Body};
        {ok, {{_, Status, _}, _, _}} -> {error, {http_status, Status}};
        {error, Reason} -> {error, {mcp_transport, Reason}}
    end.

decode_response(Id, Headers, Body) ->
    Type = proplists:get_value("content-type", Headers, ""),
    Frames = case string:split(Type, ";") of
        ["text/event-stream" | _] ->
            {Events, _} = erl_harness_sse:feed(Body, erl_harness_sse:new()),
            Events;
        _ -> [Body]
    end,
    matching_response(Id, Frames).

matching_response(Id, [Frame | Rest]) ->
    Response = try json:decode(Frame)
        catch error:_ -> undefined
        end,
    case Response of
        #{<<"id">> := Id} -> Response;
        _ -> matching_response(Id, Rest)
    end;
matching_response(_, []) ->
    undefined.
