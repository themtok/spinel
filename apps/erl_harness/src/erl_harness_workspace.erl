-%% Implements the built-in directory listing and UTF-8 file reading tools.
%% Checks workspace-relative paths, blocks reads of the private config file,
%% and caps the size of tool output.

module(erl_harness_workspace).
-behaviour(erl_harness_tool).

-export([tools/0, execute/3]).

-include_lib("kernel/include/file.hrl").

tools() ->
    Path = #{<<"type">> => <<"string">>, <<"description">> =>
        <<"Workspace-relative path using / as the separator.">>},
    [
        definition(<<"list_workspace">>, <<"List entries in a workspace directory.">>, Path, []),
        definition(<<"read_workspace_file">>, <<"Read up to 16 KiB of a UTF-8 workspace file.">>,
            Path, [<<"path">>])
    ].

execute(<<"list_workspace">>, Args, Root) ->
    with_path(Root, maps:get(<<"path">>, Args, <<".">>), fun list_directory/1);
execute(<<"read_workspace_file">>, #{<<"path">> := Path}, Root) ->
    with_path(Root, Path, fun read_file/1).

definition(Name, Description, Path, Required) ->
    #{name => Name, description => Description, parameters => #{
        <<"type">> => <<"object">>, <<"properties">> => #{<<"path">> => Path},
        <<"required">> => Required, <<"additionalProperties">> => false}}.

with_path(Root, <<".">>, Fun) ->
    Fun(Root);
with_path(Root, Path, Fun) ->
    Parts = binary:split(Path, <<"/">>, [global]),
    case lists:all(fun valid_segment/1, Parts) of
        true -> descend(Root, Parts, Fun);
        false -> {error, invalid_workspace_path}
    end.

valid_segment(<<>>) -> false;
valid_segment(Segment) ->
    binary:match(Segment, [<<0>>, <<"\\">>, <<":">>]) =:= nomatch andalso
        binary:last(Segment) =/= $. andalso binary:last(Segment) =/= $\s andalso
        not reserved_device(Segment).

reserved_device(Segment) ->
    Base = hd(binary:split(Segment, <<".">>)),
    re:run(Base, <<"^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$">>,
        [caseless, {capture, none}]) =:= match.

descend(Path, [], Fun) ->
    Fun(Path);
descend(Path, [Part | Rest], Fun) ->
    Next = filename:join(Path, unicode:characters_to_list(Part)),
    case file:read_link_info(Next) of
        {ok, #file_info{type = directory}} -> descend(Next, Rest, Fun);
        {ok, #file_info{type = regular}} when Rest =:= [] -> Fun(Next);
        {ok, _} -> {error, unsupported_workspace_path};
        {error, _} = Error -> Error
    end.

list_directory(Path) ->
    case file:list_dir(Path) of
        {ok, Entries} ->
            Visible = [unicode:characters_to_binary(E) || E <- lists:sort(Entries)],
            {ok, #{entries => lists:sublist(Visible, 200), truncated => length(Visible) > 200}};
        Error -> Error
    end.

read_file(Path) ->
    case path_key(Path) =:= path_key(erl_harness_config:private_path()) of
        true -> {error, private_config};
        false -> read_workspace_file(Path)
    end.

path_key(Path) ->
    Absolute = unicode:characters_to_binary(filename:absname(Path)),
    case os:type() of
        {win32, _} -> string:casefold(Absolute);
        _ -> Absolute
    end.

read_workspace_file(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} -> read_regular_file(Path);
        {ok, _} -> {error, expected_regular_file};
        Error -> Error
    end.

read_regular_file(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Device} ->
            try
                case file:read(Device, 16385) of
                    {ok, Bytes} -> text_result(Bytes);
                    eof -> {ok, #{text => <<>>, truncated => false}};
                    Error -> Error
                end
            after file:close(Device)
            end;
        Error -> Error
    end.

text_result(Bytes) ->
    Size = min(16384, byte_size(Bytes)),
    <<Prefix:Size/binary, Rest/binary>> = Bytes,
    case unicode:characters_to_binary(Prefix) of
        Text when is_binary(Text) -> {ok, #{text => Text, truncated => Rest =/= <<>>}};
        {incomplete, Text, _} when Rest =/= <<>> -> {ok, #{text => Text, truncated => true}};
        _ -> {error, expected_utf8}
    end.
