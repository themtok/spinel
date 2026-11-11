-%% Loads and serves the harness configuration.
%% Merges defaults, application settings, and a local override file. Validates
%% provider and tool settings and resolves the API key for model requests.

module(erl_harness_config).
-behaviour(gen_server).

-export([start_link/0, get/0, provider/0, http_options/1, private_path/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get() ->
    gen_server:call(?MODULE, settings).

provider() ->
    gen_server:call(?MODULE, provider).

private_path() ->
    gen_server:call(?MODULE, private_path).

http_options(Url) ->
    TLS = case uri_string:parse(Url) of
        #{scheme := "https"} -> [{ssl, httpc:ssl_verify_host_options(true)}];
        _ -> []
    end,
    [{autoredirect, false}, {connect_timeout, 5000}, {timeout, 30000} | TLS].

init([]) ->
    Path = filename:absname(os:getenv("ERL_HARNESS_CONFIG", "config/local.config")),
    case load(Path) of
        {ok, Settings} -> {ok, {Settings, Path}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call(settings, _, {Settings, _} = State) ->
    {reply, maps:without([api_key], Settings), State};
handle_call(private_path, _, {_, Path} = State) ->
    {reply, Path, State};
handle_call(provider, _, {Settings, _} = State) ->
    Provider = maps:with([model, url, api_key], Settings),
    {reply, Provider#{api_key := secret(maps:get(api_key, Provider))}, State}.

handle_cast(_, Settings) ->
    {noreply, Settings}.

load(Path) ->
    Defaults = #{
        model => <<"thinkingmachines/inkling-2-small:free">>,
        url => <<"https://openrouter.ai/api/v1/chat/completions">>,
        api_key => {env, "OPENROUTER_API_KEY"},
        max_model_calls => 12,
        context_budget_bytes => 96000,
        native_tools => [erl_harness_workspace],
        mcp_servers => []
    },
    Configured = application:get_env(erl_harness, settings, #{}),
    case file:consult(Path) of
        {ok, [Local]} when is_map(Local), is_map(Configured) ->
            validate(maps:merge(maps:merge(Defaults, Configured), Local));
        {error, enoent} when is_map(Configured) ->
            case os:getenv("ERL_HARNESS_CONFIG") of
                false -> validate(maps:merge(Defaults, Configured));
                _ -> {error, {config_missing, Path}}
            end;
        _ -> {error, {invalid_config, Path}}
    end.

validate(#{model := Model, url := Url, api_key := Key,
    max_model_calls := Calls, context_budget_bytes := Budget,
    native_tools := Native, mcp_servers := MCP} = Settings)
    when is_binary(Model), byte_size(Model) > 0, is_binary(Url),
         is_integer(Calls), Calls > 0, is_integer(Budget), Budget > 0,
         is_list(Native), is_list(MCP) ->
    case valid_endpoint(Url) andalso valid_key(Key) andalso
        lists:all(fun valid_native/1, Native) andalso valid_servers(MCP) of
        true -> {ok, Settings};
        false -> {error, invalid_settings}
    end;
validate(_) ->
    {error, invalid_settings}.

valid_endpoint(Url) ->
    case uri_string:parse(Url) of
        #{scheme := <<"https">>, host := Host} when Host =/= <<>> -> true;
        #{scheme := <<"http">>, host := Host} ->
            lists:member(Host, [<<"localhost">>, <<"127.0.0.1">>, <<"::1">>]);
        _ -> false
    end.

valid_key(Key) when is_binary(Key) -> true;
valid_key({env, Name}) when is_list(Name), Name =/= [] -> true;
valid_key(_) -> false.

valid_native(Module) when is_atom(Module) ->
    code:ensure_loaded(Module) =:= {module, Module} andalso
        erlang:function_exported(Module, tools, 0) andalso
        erlang:function_exported(Module, execute, 3);
valid_native(_) -> false.

valid_servers(Servers) ->
    lists:all(fun valid_server/1, Servers) andalso
        length(lists:usort([Name || #{name := Name} <- Servers])) =:= length(Servers).

valid_server(#{name := Name, url := Url, allow := Allow} = Server)
    when is_binary(Name), is_binary(Url), is_list(Allow) ->
    Env = maps:get(api_key_env, Server, ""),
    is_list(Env) andalso
        re:run(Name, <<"^[A-Za-z0-9-]+$">>, [{capture, none}]) =:= match andalso
        valid_endpoint(Url) andalso lists:all(fun erlang:is_binary/1, Allow);
valid_server(_) -> false.

secret({env, Name}) -> unicode:characters_to_binary(os:getenv(Name, ""));
secret(Key) -> Key.
