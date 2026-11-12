#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).

main(Arguments) ->
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Receipt = filename:join([Root, "_build", "checks", "examples.json"]),
    try
        ok = filelib:ensure_dir(Receipt),
        ok = file:write_file(Receipt, json:encode(#{result => 'RUNNING'})),
        Result = run(Arguments),
        Encoded = json:encode(Result),
        ok = file:write_file(Receipt, Encoded),
        io:format("~s~n", [Encoded])
    catch Class:Reason:Stack ->
        io:format(standard_error, "Example failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
        Failure = json:encode(#{result => 'FAIL', error_class => Class}),
        case file:write_file(Receipt, Failure) of
            ok -> ok;
            {error, WriteError} ->
                io:format(standard_error, "Could not record failure: ~p~n", [WriteError])
        end,
        halt(1)
    end.

run(Arguments) ->
    Started = erlang:monotonic_time(microsecond),
    ok = logger:set_primary_config(level, warning),
    ok = file:set_cwd(filename:dirname(filename:dirname(filename:absname(escript:script_name())))),
    {CodePaths, Selected} = code_paths(Arguments, []),
    ok = code:add_pathsa(CodePaths),
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Path -> Path
    end,
    Modules = case Selected of
        [] -> [filter_demo, inspect_demo, readme_demo, linked_graph, job_demo,
               options_demo, buffer_demo, pane_demo, config_demo, pipe_demo,
               hook_demo, key_demo, command_demo, control_demo];
        ["filter"] -> [filter_demo];
        ["inspect"] -> [inspect_demo];
        ["readme"] -> [readme_demo];
        ["graph"] -> [linked_graph];
        ["job"] -> [job_demo];
        ["options"] -> [options_demo];
        ["buffers"] -> [buffer_demo];
        ["panes"] -> [pane_demo];
        ["config"] -> [config_demo];
        ["pipe"] -> [pipe_demo];
        ["hooks"] -> [hook_demo];
        ["keys"] -> [key_demo];
        ["commands"] -> [command_demo];
        ["control"] -> [control_demo]
    end,
    case lists:any(fun(M) -> M =/= filter_demo end, Modules) of
        true -> true = is_list(Executable);
        false -> ok
    end,
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    TemporaryRoot = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Value -> Value
    end,
    Scratch = filename:join(TemporaryRoot, "ltm-examples-" ++ binary_to_list(Suffix)),
    ok = file:make_dir(Scratch),
    ok = file:change_mode(Scratch, 8#700),
    try
        {ok, _} = file:copy("test/tmux_fixture_watch.py", filename:join(Scratch,"tmux_fixture_watch.py")),
        true = code:add_patha(Scratch),
        lists:foreach(fun(Source) ->
            case compile:file(Source, [debug_info, warnings_as_errors, return_errors,
                                      return_warnings, {outdir, Scratch}]) of
                {ok, _, []} -> ok;
                Failure -> error({example_compile_failed, Source, Failure})
            end
        end, ["test/tmux_test_fixture.erl" | ["examples/" ++ atom_to_list(M) ++ ".erl" || M <- Modules]]),
        Results = [example(Module, Executable) || Module <- Modules],
        #{result => 'PASS', examples => Results,
          microseconds => erlang:monotonic_time(microsecond) - Started}
    after
        ok = file:del_dir_r(Scratch),
        ok = application:stop(libtmux_erlang)
    end.

code_paths(["--ebin", Ebin | Tail], Paths) -> code_paths(Tail, [Ebin | Paths]);
code_paths(Tail, []) -> {filelib:wildcard("_build/default/lib/*/ebin"), Tail};
code_paths(Tail, Paths) -> {lists:reverse(Paths), Tail}.

example(Module, _) when Module =:= filter_demo ->
    #{module => Module, output => Module:run(),
      sessions_removed => true, owned_cleanup => complete,
      transport => not_used};
example(Module, Executable) when Module =:= readme_demo ->
    #{module => Module, output => Module:run(list_to_binary(Executable)),
      sessions_removed => true, owned_cleanup => complete};
example(Module, Executable) ->
    BinaryExecutable = list_to_binary(Executable),
    {ok, Fixture} = tmux_test_fixture:start(BinaryExecutable),
    Result = try
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        Output = Module:run(Socket, BinaryExecutable),
        {ok, #{stdout := <<>>, exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"list-sessions">>, <<"-F">>, <<"#{session_id}">>]),
        Output
    after
        ok = tmux_test_fixture:ensure_closed(Fixture)
    end,
    #{module => Module, output => Result, sessions_removed => true, owned_cleanup => complete}.
