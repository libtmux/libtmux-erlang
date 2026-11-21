#!/usr/bin/env escript
%%! -noshell +S 4:4
-mode(compile).

main([Ebin, Plt, Directory]) ->
    Started = erlang:monotonic_time(microsecond),
    true = code:add_patha(Ebin),
    {module, tmux_model} = code:ensure_loaded(tmux_model),
    Modules = [model_types_ok, model_types_bad],
    lists:foreach(fun(Module) ->
        Source = filename:join(Directory, atom_to_list(Module) ++ ".erl"),
        {ok, Module} = compile:file(Source, [debug_info, warnings_as_errors,
            report_errors, report_warnings, {outdir, Directory}])
    end, Modules),
    true = code:add_patha(Directory),
    ok = model_types_ok:run(),
    Files = filelib:wildcard(filename:join(Ebin, "*.beam")) ++
        [filename:join(Directory, atom_to_list(M) ++ ".beam") || M <- Modules],
    Warnings = dialyzer:run([{analysis_type, succ_typings}, {files, Files},
                            {plts, [Plt]}]),
    Calls = [Function || {warn_failing_call, {Path, _},
                          {call, [tmux_model, Function | _]}} <- Warnings,
                         filename:basename(Path) =:= "model_types_bad.erl"],
    Other = [W || W <- Warnings, not expected_warning(W)],
    Expected = [pane, session, window, window_link],
    Passed = lists:sort(Calls) =:= Expected andalso Other =:= [],
    io:format("~s~n", [json:encode(#{result => case Passed of
        true -> 'PASS'; false -> 'FAIL' end,
        expected_rejections => Expected, rejected_calls => Calls,
        unexpected_warnings => length(Other),
        diagnostics => [unicode:characters_to_binary(
            dialyzer:format_warning(W)) || W <- Warnings],
        seconds => (erlang:monotonic_time(microsecond) - Started) / 1000000})]),
    case Passed of true -> ok; false -> halt(1) end.

expected_warning({warn_return_no_exit, {Path, _}, _}) ->
    filename:basename(Path) =:= "model_types_bad.erl";
expected_warning({warn_failing_call, {Path, _},
                  {call, [tmux_model, Function | _]}}) ->
    filename:basename(Path) =:= "model_types_bad.erl" andalso
        lists:member(Function, [pane, session, window, window_link]);
expected_warning(_) -> false.
