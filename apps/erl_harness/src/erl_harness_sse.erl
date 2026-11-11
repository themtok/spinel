-%% Incrementally parses server-sent events from incoming HTTP bytes.
%% Retains incomplete lines between chunks and returns completed data payloads.

module(erl_harness_sse).

-export([new/0, feed/2]).

-record(decoder, {pending = <<>>, data = [], skip_lf = false}).

new() ->
    #decoder{}.

feed(Bytes, #decoder{skip_lf = true} = Decoder) when Bytes =/= <<>> ->
    Rest = case Bytes of
        <<"\n", Tail/binary>> -> Tail;
        _ -> Bytes
    end,
    feed(Rest, Decoder#decoder{skip_lf = false});
feed(Bytes, #decoder{pending = Pending} = Decoder) ->
    parse_lines(<<Pending/binary, Bytes/binary>>, Decoder, []).

parse_lines(Bytes, Decoder, Events) ->
    case binary:match(Bytes, [<<"\r">>, <<"\n">>]) of
        nomatch ->
            {lists:reverse(Events), Decoder#decoder{pending = Bytes}};
        {Size, 1} ->
            <<Line:Size/binary, Delimiter, Tail/binary>> = Bytes,
            {Rest, SkipLF} = after_delimiter(Delimiter, Tail),
            {NewDecoder, NewEvents} = parse_line(Line, Decoder, Events),
            parse_lines(Rest, NewDecoder#decoder{skip_lf = SkipLF}, NewEvents)
    end.

after_delimiter($\r, <<"\n", Rest/binary>>) -> {Rest, false};
after_delimiter($\r, <<>>) -> {<<>>, true};
after_delimiter(_, Rest) -> {Rest, false}.

parse_line(<<>>, #decoder{data = []} = Decoder, Events) ->
    {Decoder, Events};
parse_line(<<>>, #decoder{data = Data} = Decoder, Events) ->
    Event = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Data))),
    {Decoder#decoder{data = []}, [Event | Events]};
parse_line(<<"data: ", Value/binary>>, Decoder, Events) ->
    add_data(Value, Decoder, Events);
parse_line(<<"data:", Value/binary>>, Decoder, Events) ->
    add_data(Value, Decoder, Events);
parse_line(<<"data">>, Decoder, Events) ->
    add_data(<<>>, Decoder, Events);
parse_line(_Other, Decoder, Events) ->
    {Decoder, Events}.

add_data(Value, #decoder{data = Data} = Decoder, Events) ->
    {Decoder#decoder{data = [Value | Data]}, Events}.
