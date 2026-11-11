#!/usr/bin/env escript
%% Rebar3 hook for the pinned educkui dependency.
%% Patches the fetched terminal code for Windows signal handling and full
%% redraws on resize, then recompiles the affected modules.

%% Apply terminal fixes to the pinned educkui dependency in _build.
main([]) ->
    Dependency = filename:join(os:getenv("REBAR_DEPS_DIR"), "educkui"),
    case os:type() of
        {win32, _} -> patch_signal_handler(Dependency);
        _ -> ok
    end,
    patch_resize(Dependency).

patch_signal_handler(Dependency) ->
    Original = <<"    _ = os:set_signal(sigwinch, handle),\n"
        "    gen_event:add_handler(erl_signal_server, ?MODULE, RuntimePid).">>,
    Replacement = <<"    case os:type() of\n"
        "        {win32, _} -> ok;\n"
        "        _ ->\n"
        "            _ = os:set_signal(sigwinch, handle),\n"
        "            gen_event:add_handler(erl_signal_server, ?MODULE, RuntimePid)\n"
        "    end.">>,
    patch(Dependency, educkui_signal_handler, Original, Replacement).

patch_resize(Dependency) ->
    Original = <<"apply_resize(State, Rows, Cols) ->\n"
        "    {ok, NewCur} = educkui_buffer:resize(State#dui_runtime_state.current_buffer, Rows, Cols),\n"
        "    {ok, NewPrev} = educkui_buffer:resize(State#dui_runtime_state.previous_buffer, Rows, Cols),\n"
        "    State1 = State#dui_runtime_state{">>,
    Replacement = <<"apply_resize(State, Rows, Cols) ->\n"
        "    %% Resizing can reflow the real terminal, invalidating the old diff baseline.\n"
        "    {NewCur, NewPrev} = create_buffers({Rows, Cols}),\n"
        "    destroy_buffers(State#dui_runtime_state.current_buffer, State#dui_runtime_state.previous_buffer),\n"
        "    BState = State#dui_runtime_state.backend_state,\n"
        "    {ok, ClearedBackend} = case State#dui_runtime_state.backend of\n"
        "        undefined -> {ok, BState};\n"
        "        Backend -> Backend:clear(BState)\n"
        "    end,\n"
        "    State1 = State#dui_runtime_state{\n"
        "        backend_state = ClearedBackend,">>,
    patch(Dependency, educkui_runtime, Original, Replacement).

patch(Dependency, Module, Original, Replacement) ->
    Source = filename:join([Dependency, "src", atom_to_list(Module) ++ ".erl"]),
    {ok, Raw} = file:read_file(Source),
    Text = binary:replace(Raw, <<"\r\n">>, <<"\n">>, [global]),
    case binary:match(Text, Replacement) of
        nomatch ->
            {_, _} = binary:match(Text, Original),
            Patched = binary:replace(Text, Original, Replacement),
            ok = file:write_file(Source, Patched),
            {ok, Module} = compile:file(Source, [debug_info, report_errors,
                nowarn_deprecated_catch, {i, filename:join(Dependency, "include")},
                {outdir, filename:join(Dependency, "ebin")}]);
        _ -> ok
    end.
