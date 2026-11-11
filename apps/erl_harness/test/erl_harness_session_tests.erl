-%% Integration tests for the session, MCP client, and educkui frontend.
%% Uses loopback fixtures to check tool round trips and provider streaming,
%% plus terminal input, resize redraws, and exit keys.

module(erl_harness_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("educkui/include/educkui.hrl").

-export([clear/1]).

tool_round_trip_test() ->
    with_provider(fun(Listener) ->
        First = receive_request(Listener),
        #{<<"tools">> := Tools} = element(2, First),
        ?assert(lists:any(fun(#{<<"function">> := #{<<"name">> := Name}}) ->
            Name =:= <<"list_workspace">>
        end, Tools)),
        reply(First, [
            choice(#{tool_calls => [#{index => 0, id => <<"call-1">>, function =>
                #{name => <<"list_workspace">>, arguments => <<"{">>}}]}, null),
            choice(#{tool_calls => [#{index => 0, function => #{arguments => <<"}">>}}]},
                <<"tool_calls">>)
        ]),
        Second = receive_request(Listener),
        #{<<"messages">> := [_, _, Assistant, Tool]} = element(2, Second),
        ?assertMatch(#{<<"tool_calls">> := [#{<<"id">> := <<"call-1">>}]}, Assistant),
        ?assertMatch(#{<<"role">> := <<"tool">>, <<"tool_call_id">> := <<"call-1">>}, Tool),
        ?assertMatch(#{<<"entries">> := [_ | _]}, json:decode(maps:get(<<"content">>, Tool))),
        reply(Second, [choice(#{content => <<"Done">>}, <<"stop">>)])
    end, fun() ->
        {ok, Id, Session} = erl_harness_controller:open(self(), "."),
        ?assertEqual({ok, Session}, erl_harness_controller:lookup(Id)),
        {ok, Turn} = erl_harness_session:submit(Session, <<"List the workspace">>),
        ?assertEqual({tool, <<"list_workspace">>, running}, event(Turn)),
        ?assertEqual({tool, <<"list_workspace">>, done}, event(Turn)),
        ?assertEqual({delta, <<"Done">>}, event(Turn)),
        ?assertEqual(done, event(Turn)),
        ?assertMatch(#{turns := [#{outcome := done, messages := [_, _, _, _]}], active := undefined},
            erl_harness_session:transcript(Session))
    end).

tui_stream_test_() ->
    [?_test(tui_stream(Enter, QuitByte)) || {Enter, QuitByte} <- [{<<"\r">>, 3}, {<<"\n">>, 17}]].

tui_stream(Enter, QuitByte) ->
    with_provider(fun(Listener) ->
        Request = receive_request(Listener),
        ?assertMatch({_, #{<<"messages">> := [_, #{<<"content">> := <<"Hello">>}]}}, Request),
        reply(Request, [choice(#{content => <<"Hello UI">>}, <<"stop">>)])
    end, fun() ->
        {ok, UI} = educkui:start([{root, erl_harness_tui}, {skip_terminal, true},
            {render_interval, 60000}]),
        try
            educkui_runtime:send_event(UI, educkui_event:resize(120, 30)),
            educkui_runtime:send_event(UI, educkui_event:key(right)),
            educkui_runtime:send_event(UI, educkui_event:key(<<"Helo">>)),
            educkui_runtime:send_event(UI, educkui_event:key(left)),
            educkui_runtime:send_event(UI, educkui_event:key(<<"l">>)),
            educkui_runtime:send_event(UI, educkui_event:key(right)),
            ?assertEqual({30, 120}, educkui_runtime:size(UI)),
            {[Submit], <<>>} = educkui_escape_parser:parse(Enter),
            educkui_runtime:send_event(UI, Submit),
            wait_for_reply(UI, 100),
            resize_redraw(UI, 54, 16),
            resize_redraw(UI, 120, 30),
            QuitRef = erlang:monitor(process, UI),
            {[Quit], <<>>} = educkui_escape_parser:parse(<<QuitByte>>),
            educkui_runtime:send_event(UI, Quit),
            receive
                {'DOWN', QuitRef, process, UI, normal} -> ok
            after 2000 ->
                error({key_did_not_quit, QuitByte})
            end
        after
            Ref = erlang:monitor(process, UI),
            educkui_runtime:shutdown(UI),
            receive {'DOWN', Ref, process, UI, _} -> ok after 2000 -> error(tui_not_stopped) end
        end
    end).

resize_redraw(UI, Cols, Rows) ->
    educkui_runtime:force_render(UI),
    #dui_runtime_state{previous_buffer = Painted} = educkui_runtime:get_state(UI),
    ?assertMatch(#dui_cell{char = <<"E">>}, educkui_buffer:get_cell(Painted, 1, 2)),
    sys:replace_state(UI, fun(State) ->
        State#dui_runtime_state{backend = ?MODULE, backend_state = uncleared}
    end),
    try
        educkui_runtime:send_event(UI, educkui_event:resize(Cols, Rows)),
        #dui_runtime_state{backend_state = BackendState, previous_buffer = Previous} =
            educkui_runtime:get_state(UI),
        ?assertEqual(cleared, BackendState),
        ?assert(educkui_cell:equal(educkui_cell:empty(), educkui_buffer:get_cell(Previous, 1, 2)))
    after
        sys:replace_state(UI, fun(State) ->
            State#dui_runtime_state{backend = undefined, backend_state = undefined}
        end)
    end,
    educkui_runtime:force_render(UI),
    #dui_runtime_state{previous_buffer = Redrawn} = educkui_runtime:get_state(UI),
    ?assertMatch(#dui_cell{char = <<"E">>}, educkui_buffer:get_cell(Redrawn, 1, 2)),
    ?assertMatch(#dui_cell{char = <<">">>}, educkui_buffer:get_cell(Redrawn, Rows - 1, 1)),
    ?assertMatch(#dui_cell{char = <<"E">>}, educkui_buffer:get_cell(Redrawn, Rows, 2)).

clear(uncleared) -> {ok, cleared}.

mcp_discovery_and_call_test() ->
    with_provider(fun(BaseUrl) ->
        #{mcp_servers => [#{name => <<"fixture">>, url => <<BaseUrl/binary, "/mcp">>,
            allow => [<<"ping">>]}]}
    end, fun(Listener) ->
        {Init, #{<<"method">> := <<"initialize">>, <<"id">> := InitId}, _} =
            receive_request(Listener, <<"/mcp">>),
        http_reply(Init, "200 OK", "application/json", ["Mcp-Session-Id: fixture-session\r\n"],
            json:encode(#{jsonrpc => <<"2.0">>, id => InitId,
                result => #{protocolVersion => <<"2025-11-25">>, capabilities => #{tools => #{}}}})),
        {Notice, #{<<"method">> := <<"notifications/initialized">>}, NoticeHeaders} =
            receive_request(Listener, <<"/mcp">>),
        ?assertEqual(<<"fixture-session">>, header(<<"mcp-session-id">>, NoticeHeaders)),
        http_reply(Notice, "202 Accepted", "application/json", [], <<>>),
        {List, #{<<"method">> := <<"tools/list">>, <<"id">> := ListId}, _} =
            receive_request(Listener, <<"/mcp">>),
        Schema = #{type => <<"object">>},
        rpc_reply(List, ListId, #{tools => [#{name => <<"ping">>, inputSchema => Schema},
            #{name => <<"disallowed">>, inputSchema => Schema}]}),
        {Call, #{<<"method">> := <<"tools/call">>, <<"id">> := CallId,
            <<"params">> := #{<<"name">> := <<"ping">>}}, CallHeaders} =
            receive_request(Listener, <<"/mcp">>),
        ?assertEqual(<<"2025-11-25">>, header(<<"mcp-protocol-version">>, CallHeaders)),
        rpc_reply(Call, CallId, #{content => [#{type => <<"text">>, text => <<"pong">>}]})
    end, fun() ->
        Catalog = wait_for_catalog(100),
        ?assertEqual([<<"fixture__ping">>], maps:keys(Catalog)),
        Call = #{function => #{name => <<"fixture__ping">>, arguments => <<"{}">>}},
        {ok, Execution} = erl_harness_tool:resolve(Call, Catalog),
        ?assertMatch({ok, #{<<"content">> := [#{<<"text">> := <<"pong">>}]}},
            erl_harness_tool:execute(Execution, "."))
    end).

wait_for_catalog(0) ->
    error(mcp_catalog_missing);
wait_for_catalog(Attempts) ->
    case erl_harness_tool:catalog([]) of
        Catalog when map_size(Catalog) > 0 -> Catalog;
        _ ->
            receive after 20 -> ok end,
            wait_for_catalog(Attempts - 1)
    end.

wait_for_reply(_, 0) ->
    error(tui_reply_missing);
wait_for_reply(UI, Attempts) ->
    #dui_runtime_state{root_state = State} = educkui_runtime:get_state(UI),
    case State of
        #{entries := [{assistant, <<"Hello UI">>} | _], turn := undefined} -> ok;
        _ ->
            receive after 20 -> ok end,
            wait_for_reply(UI, Attempts - 1)
    end.

event(Turn) ->
    receive {harness, Turn, Event} -> Event after 2000 -> error(session_timeout) end.

choice(Delta, Reason) ->
    #{choices => [#{index => 0, delta => Delta, finish_reason => Reason}]}.

with_provider(Serve, Test) ->
    with_provider(fun(_) -> #{} end, Serve, Test).

with_provider(Extra, Serve, Test) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127, 0, 0, 1}}, {packet, http_bin}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    BaseUrl = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port)]),
    URL = <<BaseUrl/binary, "/completion">>,
    Settings = maps:merge(#{model => <<"fixture">>, url => URL, api_key => <<"fixture-key">>},
        Extra(BaseUrl)),
    {ok, Cwd} = file:get_cwd(),
    Path = filename:join([Cwd, "_build", "fixture-" ++ os:getpid() ++ "-" ++
        integer_to_list(erlang:unique_integer([positive])) ++ ".config"]),
    ok = file:write_file(Path, io_lib:format("~p.~n", [Settings]), [exclusive]),
    Previous = os:getenv("ERL_HARNESS_CONFIG"),
    true = os:putenv("ERL_HARNESS_CONFIG", Path),
    {ok, Apps} = application:ensure_all_started(erl_harness),
    Server = spawn_link(fun() -> Serve(Listener) end),
    try Test()
    after
        unlink(Server),
        exit(Server, shutdown),
        gen_tcp:close(Listener),
        lists:foreach(fun application:stop/1, lists:reverse(Apps)),
        case Previous of
            false -> os:unsetenv("ERL_HARNESS_CONFIG");
            _ -> os:putenv("ERL_HARNESS_CONFIG", Previous)
        end,
        file:delete(Path)
    end.

receive_request(Listener) ->
    {Socket, Body, Headers} = receive_request(Listener, <<"/completion">>),
    ?assertEqual(<<"Bearer fixture-key">>, maps:get('Authorization', Headers)),
    {Socket, Body}.

receive_request(Listener, Path) ->
    {ok, Socket} = gen_tcp:accept(Listener, 2000),
    {ok, {http_request, 'POST', {abs_path, Path}, _}} =
        gen_tcp:recv(Socket, 0, 2000),
    Headers = receive_headers(Socket, #{}),
    Length = binary_to_integer(maps:get('Content-Length', Headers)),
    ok = inet:setopts(Socket, [{packet, raw}]),
    {ok, Body} = gen_tcp:recv(Socket, Length, 2000),
    {Socket, json:decode(Body), Headers}.

header(Name, Headers) ->
    [Value] = [Value || {Key, Value} <- maps:to_list(Headers), is_binary(Key),
        string:lowercase(Key) =:= Name],
    Value.

receive_headers(Socket, Headers) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, {http_header, _, Name, _, Value}} -> receive_headers(Socket, Headers#{Name => Value});
        {ok, http_eoh} -> Headers
    end.

reply({Socket, _}, Frames) ->
    Body = [["data: ", json:encode(Frame), "\n\n"] || Frame <- Frames] ++ ["data: [DONE]\n\n"],
    http_reply(Socket, "200 OK", "text/event-stream", [], Body).

rpc_reply(Socket, Id, Result) ->
    http_reply(Socket, "200 OK", "application/json", [],
        json:encode(#{jsonrpc => <<"2.0">>, id => Id, result => Result})).

http_reply(Socket, Status, Type, Headers, Body) ->
    ok = gen_tcp:send(Socket, ["HTTP/1.1 ", Status, "\r\nContent-Type: ", Type, "\r\n", Headers,
        "Connection: close\r\nContent-Length: ", integer_to_list(iolist_size(Body)),
        "\r\n\r\n", Body]),
    gen_tcp:close(Socket).
