#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).

main(Arguments) ->
    try run(Arguments) of
        Result ->
            Encoded = json:encode(Result),
            ok = filelib:ensure_dir("_build/checks/examples.json"),
            ok = file:write_file("_build/checks/examples.json", Encoded),
            io:format("~s~n", [Encoded])
    catch Class:Reason:Stack ->
        io:format(standard_error, "Example failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
        halt(1)
    end.

run(Arguments) ->
    Started = erlang:monotonic_time(microsecond),
    ok = logger:set_primary_config(level, warning),
    ok = file:set_cwd(filename:dirname(filename:dirname(filename:absname(escript:script_name())))),
    {CodePaths, Selected} = case Arguments of
        ["--ebin", Ebin | Tail] -> {[Ebin], Tail};
        _ -> {filelib:wildcard("_build/default/lib/*/ebin"), Arguments}
    end,
    ok = code:add_pathsa(CodePaths),
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Path -> Path
    end,
    true = is_list(Executable),
    Modules = case Selected of
        [] -> [filter_demo, inspect_demo, readme_demo, linked_graph, job_demo,
               options_demo, buffer_demo, pane_demo, config_demo, pipe_demo, hook_demo];
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
        ["hooks"] -> [hook_demo]
    end,
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    Scratch = binary_to_list(<<"/tmp/ltm-examples-", Suffix/binary>>),
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
        Results = [example(Module, list_to_binary(Executable)) || Module <- Modules],
        #{result => 'PASS', examples => Results,
          microseconds => erlang:monotonic_time(microsecond) - Started}
    after
        ok = file:del_dir_r(Scratch),
        ok = application:stop(libtmux_erlang)
    end.

example(filter_demo, _) ->
    #{module => filter_demo, output => filter_demo:run(),
      sessions_removed => true, owned_cleanup => complete,
      transport => not_used};
example(Module, Executable) ->
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    Result = try
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        Output = Module:run(Socket, Executable),
        {ok, #{stdout := <<>>, exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"list-sessions">>, <<"-F">>, <<"#{session_id}">>]),
        Output
    after
        ok = tmux_test_fixture:ensure_closed(Fixture)
    end,
    #{module => Module, output => Result, sessions_removed => true, owned_cleanup => complete}.
