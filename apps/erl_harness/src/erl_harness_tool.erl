-%% Defines the native tool behaviour and shared dispatch path.
%% Builds the native and MCP tool catalog, exposes schemas to the model, and
%% checks tool names and arguments before invoking the selected backend.

module(erl_harness_tool).

-export([catalog/1, schemas/1, resolve/2, execute/2]).
-export_type([definition/0]).

-type definition() :: #{name := binary(), description := binary(), parameters := map()}.
-callback tools() -> [definition()].
-callback execute(binary(), map(), file:filename_all()) -> {ok, term()} | {error, term()}.

catalog(NativeModules) ->
    Native = [{maps:get(name, Tool), {Tool, {native, Module}}}
        || Module <- NativeModules, Tool <- Module:tools()],
    maps:from_list(erl_harness_mcp:catalog() ++ Native).

schemas(Catalog) ->
    [#{type => <<"function">>, function => Definition}
        || {_, {Definition, _}} <- lists:sort(maps:to_list(Catalog))].

resolve(#{function := #{name := Name, arguments := Arguments}}, Catalog) ->
    case maps:find(Name, Catalog) of
        {ok, {#{parameters := Schema}, Backend}} ->
            case decode_args(Arguments) of
                {ok, Args} ->
                    case valid_args(Args, Schema) of
                        true -> {ok, {Backend, Name, Args}};
                        false -> {error, invalid_arguments}
                    end;
                Error -> Error
            end;
        error -> {error, tool_not_allowed}
    end.

execute({{native, Module}, Name, Args}, Workspace) ->
    Module:execute(Name, Args, Workspace);
execute({{mcp, Client, Name}, _, Args}, _) ->
    erl_harness_mcp_client:call_tool(Client, Name, Args).

decode_args(Arguments) ->
    try json:decode(Arguments) of
        Args when is_map(Args) -> {ok, Args};
        _ -> {error, invalid_arguments}
    catch error:_ -> {error, invalid_arguments}
    end.

valid_args(Args, Schema) ->
    Required = maps:get(<<"required">>, Schema, []),
    Properties = maps:get(<<"properties">>, Schema, #{}),
    Additional = maps:get(<<"additionalProperties">>, Schema, true),
    lists:all(fun(Key) -> maps:is_key(Key, Args) end, Required) andalso
        maps:fold(fun(Key, Value, Acc) ->
            Acc andalso case maps:find(Key, Properties) of
                {ok, Property} -> valid_type(Value, Property);
                error -> Additional =/= false
            end
        end, true, Args).

valid_type(Value, #{<<"type">> := <<"string">>}) -> is_binary(Value);
valid_type(Value, #{<<"type">> := <<"integer">>}) -> is_integer(Value);
valid_type(Value, #{<<"type">> := <<"number">>}) -> is_number(Value);
valid_type(Value, #{<<"type">> := <<"boolean">>}) -> is_boolean(Value);
valid_type(Value, #{<<"type">> := <<"array">>}) -> is_list(Value);
valid_type(Value, #{<<"type">> := <<"object">>}) -> is_map(Value);
valid_type(_, _) -> true.
