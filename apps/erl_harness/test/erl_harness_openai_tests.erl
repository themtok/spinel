-%% Exercises the HTTP streaming transport against a loopback server.
%% Checks incremental delivery, HTTP errors, incomplete streams, and cancellation.

module(erl_harness_openai_tests).

-include_lib("eunit/include/eunit.hrl").

streams_incrementally_test() ->
    with_endpoint(fun(Socket, Test) ->
        ok = gen_tcp:send(Socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n",
            "Transfer-Encoding: chunked\r\n\r\n"
        ]),
        send_chunk(Socket, <<": heartbeat\r\ndata: {\"choices\":[">>),
        send_chunk(Socket, <<"{\"delta\":{\"content\":\"Hello\"}}]}\r">>),
        send_chunk(Socket, <<"\n\r">>),
        await_chunk_delivery(Socket, 20),
        Test ! sending_done,
        send_chunk(Socket, <<"\ndata: [DONE]\n\n">>),
        ok = gen_tcp:send(Socket, <<"0\r\n\r\n">>)
    end, fun(Server) ->
        {ok, Ref} = erl_harness_openai:stream(request()),
        Request = receive {request, Body} -> Body after 2000 -> error(no_request) end,
        ?assertEqual(<<"fixture-model">>, maps:get(<<"model">>, Request)),
        ?assertEqual(true, maps:get(<<"stream">>, Request)),
        ?assertMatch({chunk, #{<<"choices">> := [
            #{<<"delta">> := #{<<"content">> := <<"Hello">>}}
        ]}}, next(Ref)),
        Server ! continue,
        receive sending_done -> ok after 2000 -> error(no_done_sent) end,
        ?assertEqual(done, next(Ref))
    end).

http_error_test() ->
    with_endpoint(fun(Socket, _Test) ->
        ok = gen_tcp:send(Socket, <<"HTTP/1.1 401 Unauthorized\r\n",
            "Content-Length: 6\r\nConnection: close\r\n\r\ndenied">>)
    end, fun(_Server) ->
        {ok, Ref} = erl_harness_openai:stream(request()),
        ?assertEqual({error, {http_status, 401, <<"denied">>}}, next(Ref))
    end).

incomplete_stream_test() ->
    with_endpoint(fun(Socket, _Test) ->
        ok = gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream\r\nContent-Length: 10\r\n",
            "Connection: close\r\n\r\ndata: {}\n\n">>)
    end, fun(_Server) ->
        {ok, Ref} = erl_harness_openai:stream(request()),
        ?assertEqual({chunk, #{}}, next(Ref)),
        ?assertEqual({error, incomplete_stream}, next(Ref))
    end).

cancel_test() ->
    with_endpoint(fun(Socket, Test) ->
        ok = gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n">>),
        send_chunk(Socket, <<"data: {}\n\n">>),
        %% Inets can hold the first chunk when it arrives with the headers.
        receive after 40 -> ok end,
        Result = case send_chunk(Socket, <<": heartbeat\n\n">>) of
            ok -> gen_tcp:recv(Socket, 0, 2000);
            {error, _} = Error -> Error
        end,
        Test ! {socket_result, Result}
    end, fun(_Server) ->
        {ok, Ref} = erl_harness_openai:stream(request()),
        ?assertEqual({chunk, #{}}, next(Ref)),
        ?assertEqual(ok, erl_harness_openai:cancel(Ref)),
        ?assertEqual({error, cancelled}, next(Ref)),
        receive
            {socket_result, Result} ->
                %% Winsock can report an abort if the heartbeat races cancellation.
                ?assert(lists:member(Result, [{error, closed}, {error, econnaborted}]))
        after 2500 ->
            error(socket_left_open)
        end
    end).

request() ->
    #{model => <<"fixture-model">>, stream => false,
        messages => [#{role => <<"user">>, content => <<"Hi">>}]}.

next(Ref) ->
    receive
        {openai, Ref, Event} -> Event
    after 2000 ->
        error(stream_timeout)
    end.

with_endpoint(Respond, Test) ->
    {ok, Apps} = application:ensure_all_started(erl_harness),
    {ok, Listener} = gen_tcp:listen(0, [
        binary, {active, false}, {ip, {127, 0, 0, 1}}, {packet, http_bin}
    ]),
    {ok, {_, Port}} = inet:sockname(Listener),
    OldUrl = application:get_env(erl_harness, openai_base_url),
    OldKey = os:getenv("OPENAI_API_KEY"),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1/",
    ok = application:set_env(erl_harness, openai_base_url, Url),
    true = os:putenv("OPENAI_API_KEY", "fixture-key"),
    Caller = self(),
    Server = spawn_link(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener, 2000),
        {ok, {http_request, 'POST', {abs_path, <<"/v1/chat/completions">>}, _}} =
            gen_tcp:recv(Socket, 0, 2000),
        Headers = receive_headers(Socket, #{}),
        ?assertEqual(<<"Bearer fixture-key">>, maps:get('Authorization', Headers)),
        Length = binary_to_integer(maps:get('Content-Length', Headers)),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, Body} = gen_tcp:recv(Socket, Length, 2000),
        Caller ! {request, json:decode(Body)},
        Respond(Socket, Caller),
        gen_tcp:close(Socket)
    end),
    try Test(Server)
    after
        unlink(Server),
        exit(Server, shutdown),
        gen_tcp:close(Listener),
        restore_url(OldUrl),
        restore_key(OldKey),
        lists:foreach(fun application:stop/1, lists:reverse(Apps))
    end.

receive_headers(Socket, Headers) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, {http_header, _, Name, _, Value}} ->
            receive_headers(Socket, Headers#{Name => Value});
        {ok, http_eoh} ->
            Headers
    end.

restore_url({ok, Url}) -> application:set_env(erl_harness, openai_base_url, Url);
restore_url(undefined) -> application:unset_env(erl_harness, openai_base_url).

restore_key(false) -> os:unsetenv("OPENAI_API_KEY");
restore_key(Key) -> os:putenv("OPENAI_API_KEY", Key).

send_chunk(Socket, Bytes) ->
    gen_tcp:send(Socket, [integer_to_list(byte_size(Bytes), 16), "\r\n", Bytes, "\r\n"]).

await_chunk_delivery(_, 0) ->
    error(chunk_not_delivered);
await_chunk_delivery(Socket, Attempts) ->
    receive
        continue -> ok
    after 50 ->
        %% Inets may buffer chunks that share the response headers' TCP read.
        ok = send_chunk(Socket, <<": heartbeat\n\n">>),
        await_chunk_delivery(Socket, Attempts - 1)
    end.
