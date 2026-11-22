%% Measure complete child VM and compiled-escript startup through the native helper.
%% Usage: escript scripts/check/measure_startup.erl
-module(measure_startup).
-mode(compile).
-export([main/1, summarize/1]).

-spec main([string()]) -> no_return().
main([]) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    Started = erlang:monotonic_time(microsecond),
    Base = #{head => script_util:git(["rev-parse", "HEAD"], Root),
             source_sha256 => script_util:sha256_hex({file, escript:script_name()}),
             runtime => list_to_binary(erlang:system_info(system_version)),
             runtime_flags => environment("ERL_FLAGS"),
             runner_os => environment("RUNNER_OS"), runner_arch => environment("RUNNER_ARCH"),
             runner_image => environment("ImageOS"), image_version => environment("ImageVersion"),
             github_run_id => environment("GITHUB_RUN_ID"),
             hosted_actions => os:getenv("GITHUB_ACTIONS") =:= "true",
             warmup_runs => 3, measured_runs => 10,
             scope => <<"Native helper launch through child exit; includes all VM/escript startup">>},
    Result = try
        script_util:with_tmp_dir("erlang-startup", fun(Temp) ->
            Script = filename:join(Temp, "startup.erl"),
            ok = file:write_file(Script, "-mode(compile).\nmain([]) -> halt(0).\n"),
            Base#{result => <<"PASS">>,
                  child_vm => measure(["erl", "-noshell", "-eval", "halt(0)."]),
                  compiled_escript => measure(["escript", Script])}
        end)
    catch error:{startup_failed, Failure} -> Base#{result => <<"FAIL">>, error => Failure}
    end,
    Final = Result#{seconds => (erlang:monotonic_time(microsecond) - Started) / 1.0e6},
    Path = filename:join(Root, "_build/checks/startup.json"),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, [json:format(Final), $\n]),
    io:format("~s~n", [json:format(Final)]),
    halt(case maps:get(result, Final) of <<"PASS">> -> 0; _ -> 1 end).

measure([Program | Arguments]) ->
    Run = fun() -> script_util:run(Program, Arguments, #{timeout_ms => 6000}) end,
    _ = summarize([Run() || _ <- lists:seq(1, 3)]),
    summarize([Run() || _ <- lists:seq(1, 10)]).

-doc "Summarize successful whole-command timings; refuse any failed sample.".
-spec summarize([script_util:result(), ...]) -> map().
summarize(Results) ->
    lists:foreach(fun(#{status := 0}) -> ok;
                     (Other) -> error({startup_failed, maps:without([stdout, stderr], Other)})
                  end, Results),
    Samples = [Seconds || #{seconds := Seconds} <- Results],
    Sorted = lists:sort(Samples),
    N = length(Sorted),
    Median = (lists:nth((N + 1) div 2, Sorted) + lists:nth((N + 2) div 2, Sorted)) / 2,
    #{samples_seconds => Samples, min_seconds => hd(Sorted),
      median_seconds => Median, max_seconds => lists:last(Sorted)}.

environment(Name) ->
    case os:getenv(Name) of false -> null; Value -> list_to_binary(Value) end.
