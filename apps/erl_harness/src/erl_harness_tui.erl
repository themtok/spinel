-%% Implements the educkui terminal client.
%% Maps keys to prompt editing, submission, scrolling, and cancellation, then
%% renders session events as a live transcript and status line.

module(erl_harness_tui).
-behaviour(educkui_elm).

-include_lib("educkui/include/educkui.hrl").

-export([run/0, init/1, event_to_msg/2, update/2, view/1]).

run() ->
    case application:ensure_all_started(erl_harness) of
        {ok, _} -> educkui:run([{root, ?MODULE}, {backend, raw}]);
        {error, _} = Error -> Error
    end.

init(_) ->
    Runtime = self(),
    ResizePoll = case os:type() of {win32, _} -> 500; _ -> infinity end,
    Relay = spawn(fun() ->
        relay(Runtime, erlang:monitor(process, Runtime), undefined, ResizePoll)
    end),
    {ok, Workspace} = file:get_cwd(),
    {Session, Status} = case erl_harness_controller:open(Relay, Workspace) of
        {ok, _, Pid} ->
            Relay ! {watch, Pid},
            {Pid, <<"Ready">>};
        {error, Reason} -> {undefined, status_error(Reason)}
    end,
    #{model := Model} = erl_harness_config:get(),
    #{session => Session, model => Model, status => Status, turn => undefined,
        input => educkui_lineedit:new(), entries => [], output => [], rows => 24,
        cols => 80, scroll => 0}.

relay(Runtime, Monitor, SessionRef, ResizePoll) ->
    receive
        {watch, Session} ->
            relay(Runtime, Monitor, erlang:monitor(process, Session), ResizePoll);
        {harness, Turn, Event} ->
            educkui_runtime:send_message(Runtime, root, {turn_event, Turn, Event}),
            relay(Runtime, Monitor, SessionRef, ResizePoll);
        {'DOWN', Monitor, process, _, _} -> ok;
        {'DOWN', SessionRef, process, _, _} ->
            educkui_runtime:send_message(Runtime, root, session_closed),
            relay(Runtime, Monitor, undefined, ResizePoll)
    after ResizePoll ->
        Runtime ! {educkui_sigwinch},
        relay(Runtime, Monitor, SessionRef, ResizePoll)
    end.

event_to_msg(#dui_event{type = resize, width = Cols, height = Rows}, _) ->
    {msg, {resize, Rows, Cols}};
event_to_msg(#dui_event{type = custom, key = message, content = {root, Message}}, _) ->
    {msg, Message};
event_to_msg(#dui_event{type = key, key = <<"q">>, modifiers = [ctrl]}, _) -> {msg, quit};
event_to_msg(#dui_event{type = key, key = <<"c">>, modifiers = [ctrl]}, _) -> {msg, cancel};
event_to_msg(#dui_event{type = key, key = esc}, _) -> {msg, cancel};
event_to_msg(#dui_event{type = key, key = enter}, _) -> {msg, submit};
%% educkui decodes a line feed from the terminal as Ctrl+J.
event_to_msg(#dui_event{type = key, key = <<"j">>, modifiers = [ctrl]}, _) -> {msg, submit};
event_to_msg(#dui_event{type = key, key = up}, _) -> {msg, {scroll, 1}};
event_to_msg(#dui_event{type = key, key = down}, _) -> {msg, {scroll, -1}};
event_to_msg(#dui_event{type = key, key = page_up}, _) -> {msg, {scroll, 10}};
event_to_msg(#dui_event{type = key, key = page_down}, _) -> {msg, {scroll, -10}};
event_to_msg(#dui_event{type = key, key = Key, modifiers = []}, _)
    when Key =:= left; Key =:= right; Key =:= home; Key =:= 'end';
         Key =:= delete; Key =:= backspace ->
    {msg, {edit, Key}};
event_to_msg(#dui_event{type = key, key = Text, modifiers = []}, _) when is_binary(Text) ->
    {msg, {insert, Text}};
event_to_msg(#dui_event{type = paste, content = Text}, _) when is_binary(Text) ->
    {msg, {insert, Text}};
event_to_msg(_, _) -> ignore.

update(quit, State) ->
    {State, [educkui_command:quit()]};
update(cancel, #{session := Session, turn := Turn} = State) when is_reference(Turn) ->
    try erl_harness_session:cancel(Session)
    catch exit:_ -> ok
    end,
    {State, []};
update(cancel, State) ->
    {State, [educkui_command:quit()]};
update(submit, #{session := Session, turn := undefined, input := Input} = State)
    when is_pid(Session) ->
    Text = string:trim(educkui_lineedit:value(Input)),
    case Text of
        <<>> -> {State, []};
        _ -> submit(Session, Text, State)
    end;
update(submit, State) -> {State, []};
update({insert, Text}, #{input := Input} = State) ->
    Clean = binary:replace(safe_text(Text), <<"\n">>, <<" ">>, [global]),
    case byte_size(educkui_lineedit:value(Input)) + byte_size(Clean) =< 32000 of
        true -> {State#{input := educkui_lineedit:insert(Clean, Input)}, []};
        false -> {State#{status := <<"Input is too long">>}, []}
    end;
update({edit, Key}, #{input := Input} = State) ->
    {State#{input := edit(Key, Input)}, []};
update({resize, Rows, Cols}, State) ->
    {State#{rows := Rows, cols := Cols}, []};
update({scroll, Offset}, #{scroll := Scroll} = State) ->
    Max = max(0, length(transcript_lines(State)) - body_height(State)),
    {State#{scroll := min(Max, max(0, Scroll + Offset))}, []};
update({turn_event, Turn, Event}, #{turn := Turn} = State) ->
    {turn_event(Event, State), []};
update(session_closed, State) ->
    {finish(<<"Session closed">>, State#{session := undefined}), []};
update(_, State) -> {State, []}.

submit(Session, Text, #{entries := Entries} = State) ->
    Submitted = try erl_harness_session:submit(Session, Text)
        catch exit:_ -> {error, session_unavailable}
        end,
    case Submitted of
        {ok, Turn} ->
            {State#{turn := Turn, input := educkui_lineedit:new(), scroll := 0,
                entries := keep_entries([{user, Text} | Entries]), status := <<"Waiting for model">>}, []};
        {error, Reason} -> {State#{status := status_error(Reason)}, []}
    end.

edit(Direction, Input) when Direction =:= left; Direction =:= right ->
    educkui_lineedit:move(Direction, Input);
edit(Key, Input) -> educkui_lineedit:Key(Input).

turn_event({delta, Text}, #{output := Output} = State) ->
    State#{output := [safe_text(Text) | Output], status := <<"Streaming">>};
turn_event({tool, Name, Status}, State) ->
    Label = safe_text(Name),
    State#{status := <<"Tool: ", Label/binary, " (", (atom_to_binary(Status))/binary, ")">>};
turn_event(done, State) -> finish(<<"Ready">>, State);
turn_event(cancelled, State) -> finish(<<"Cancelled">>, State);
turn_event({error, Reason}, State) -> finish(status_error(Reason), State).

finish(Status, #{entries := Entries, output := Output} = State) ->
    Updated = case Output of
        [] -> Entries;
        _ -> keep_entries([{assistant, iolist_to_binary(lists:reverse(Output))} | Entries])
    end,
    State#{entries := Updated, turn := undefined, output := [], status := Status}.

keep_entries(Entries) -> lists:sublist(Entries, 24).

view(#{cols := Cols, scroll := Scroll, model := Model, input := Input, status := Status} = State) ->
    Height = body_height(State),
    Lines = transcript_lines(State),
    End = max(0, length(Lines) - Scroll),
    Body = lists:sublist(Lines, max(1, End - Height + 1), min(Height, End)),
    Prompt = input_line(Input, Cols),
    educkui_render_node:stack(vertical, [
        line(<<" Erlang Harness  /  ", Model/binary>>, Cols, #{bold => true, fg => cyan}),
        line(<<" ", Status/binary>>, Cols, #{fg => yellow}),
        educkui_render_node:text(<<>>)
        | [line(Text, Cols, Style) || {Text, Style} <- Body] ++
          lists:duplicate(Height - length(Body), educkui_render_node:text(<<>>)) ++ [
            line(Prompt, Cols, #{bold => true}),
            line(<<" Enter Send   Esc/Ctrl+C Cancel/Exit   Ctrl+Q Exit   Up/Down Scroll">>,
                Cols, #{dim => true})
          ]
    ]).

body_height(#{rows := Rows}) -> max(0, Rows - 5).

line(Text, Cols, Style) ->
    {Visible, _} = educkui_display_width:truncate(Text, max(0, Cols)),
    educkui_render_node:text(Visible, educkui_style:from(Style)).

input_line(Input, Cols) ->
    Chars = string:to_graphemes(educkui_lineedit:value(Input)),
    Cursor = educkui_lineedit:cursor(Input),
    {Before, After} = lists:split(Cursor, Chars),
    {Tail, _} = educkui_display_width:truncate(
        unicode:characters_to_binary(lists:reverse(Before)), max(0, Cols - 5)),
    unicode:characters_to_binary(["> ", lists:reverse(string:to_graphemes(Tail)), "|", After]).

transcript_lines(#{entries := Entries, output := Output, cols := Cols}) ->
    Active = case Output of
        [] -> Entries;
        _ -> [{assistant, iolist_to_binary(lists:reverse(Output))} | Entries]
    end,
    lists:append([entry_lines(Role, Text, max(2, Cols)) || {Role, Text} <- lists:reverse(Active)]).

entry_lines(Role, Text, Cols) ->
    Title = case Role of user -> <<"You">>; assistant -> <<"Assistant">> end,
    [{Title, #{fg => cyan, bold => true}} |
        [{Line, #{}} || Part <- binary:split(Text, <<"\n">>, [global]), Line <- wrap(Part, Cols)]] ++
        [{<<>>, #{}}].

wrap(Text, Cols) ->
    wrap_graphemes(string:to_graphemes(Text), Cols, 0, []).

wrap_graphemes([Grapheme | Rest], Cols, Width, Line) ->
    Char = unicode:characters_to_binary([Grapheme]),
    NextWidth = educkui_display_width:width(Char),
    case Width + NextWidth > Cols andalso Line =/= [] of
        true -> [line_binary(Line) | wrap_graphemes(Rest, Cols, NextWidth, [Char])];
        false -> wrap_graphemes(Rest, Cols, Width + NextWidth, [Char | Line])
    end;
wrap_graphemes([], _, _, Line) ->
    [line_binary(Line)].

line_binary(Line) -> iolist_to_binary(lists:reverse(Line)).

safe_text(Text) ->
    re:replace(Text, <<"[\\x00-\\x09\\x0B-\\x1F\\x7F-\\x9F]">>, <<" ">>,
        [unicode, global, {return, binary}]).

status_error(Reason) ->
    Text = unicode:characters_to_binary(io_lib:format("~P", [Reason, 5])),
    Clean = binary:replace(safe_text(Text), <<"\n">>, <<" ">>, [global]),
    <<"Error: ", Clean/binary>>.
