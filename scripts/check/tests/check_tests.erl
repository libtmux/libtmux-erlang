-module(check_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

inner_runs_one_module_test() ->
    ?assertEqual([["rebar3", "eunit", "--module", "tmux_model_tests"]],
                 check:plan(inner, "tmux_model_tests")).

budgets_follow_the_loop_table_test() ->
    ?assertEqual([5, 30, 300], [check:budget(Tier) || Tier <- [inner, mid, outer]]).

every_script_a_plan_runs_exists_test() ->
    Scripts = [Path || Tier <- [mid, outer], [Program, Path | _] <- check:plan(Tier, none),
                       Program =:= "escript"],
    ?assertNotEqual([], Scripts),
    lists:foreach(fun(Path) -> ?assert(filelib:is_regular(Path), Path) end, Scripts).

mid_runs_the_ported_unit_tests_test() ->
    Mid = check:plan(mid, none),
    ?assert(lists:member(["rebar3", "eunit"], Mid)),
    ?assert(lists:member(["rebar3", "compile"], Mid)),
    ?assertEqual(["git", "diff", "--check"], lists:last(Mid)).

outer_runs_the_integration_suites_test() ->
    Outer = check:plan(outer, none),
    lists:foreach(fun(Command) -> ?assert(lists:member(Command, Outer), Command) end,
                  [["rebar3", "dialyzer"], ["rebar3", "ct"],
                   ["escript", "scripts/check/run_examples.escript"]]).

properties_run_in_the_logged_runner_with_an_outer_budget_test() ->
    ?assertEqual([["rebar3", "as", "property", "proper", "--dir", "property",
                   "--numtests", "300"]], check:plan(properties, none)),
    ?assertEqual(300, check:budget(properties)).

a_loop_passes_only_when_nothing_failed_inside_the_budget_test() ->
    ?assert(check:passed(false, 4.9, inner)),
    ?assertNot(check:passed(true, 1.0, inner)),
    ?assertNot(check:passed(false, 5.0, inner)).

passing_commands_all_run_test() ->
    {Failed, Results} = check:run([["a"], ["b"]], 10, fun(_, _) -> outcome(0, false) end),
    ?assertNot(Failed),
    ?assertMatch([{["a"], _}, {["b"], _}], Results).

first_failure_ends_the_loop_test() ->
    Runner = fun(["bad"], _) -> outcome(1, false); (_, _) -> outcome(0, false) end,
    {Failed, Results} = check:run([["ok"], ["bad"], ["never"]], 10, Runner),
    ?assert(Failed),
    ?assertMatch([{["ok"], _}, {["bad"], _}], Results).

timeout_counts_as_failure_test() ->
    {Failed, [_]} = check:run([["slow"]], 10, fun(_, _) -> outcome(137, true) end),
    ?assert(Failed).

each_command_gets_the_remaining_budget_test() ->
    Self = self(),
    Runner = fun(_, Remaining) -> Self ! {remaining, Remaining}, outcome(0, false) end,
    {false, _} = check:run([["a"]], 5, Runner),
    Remaining = receive {remaining, Milliseconds} -> Milliseconds end,
    ?assert(Remaining =< 5000 andalso Remaining > 4000).

exhausted_budget_is_reported_before_running_test() ->
    Self = self(),
    Runner = fun(_, _) -> Self ! ran, outcome(0, false) end,
    {Failed, Results} = check:run([["first"]], 0, Runner),
    ?assert(Failed),
    ?assertEqual([{["first"], budget_exceeded}], Results),
    receive ran -> ?assert(false) after 0 -> ok end.

real_runner_reports_status_output_and_deadline_test() ->
    Options = #{cwd => element(2, file:get_cwd()), env => [], timeout_ms => 5000},
    ?assertMatch(#{exit_status := 0, timed_out := false, output := <<"hi\n">>},
                 check:runner(["echo", "hi"], Options)),
    ?assertMatch(#{exit_status := 1, timed_out := false}, check:runner(["false"], Options)),
    ?assertMatch(#{timed_out := true},
                 check:runner(["sleep", "30"], Options#{timeout_ms => 200})).

real_runner_retains_both_streams_when_a_command_fails_test() ->
    Options = #{cwd => element(2, file:get_cwd()), env => [], timeout_ms => 1000},
    ?assertMatch(#{exit_status := 7, timed_out := false, output := <<"out\nerr\n">>},
        check:runner(["sh", "-c", "printf 'out\\n'; printf 'err\\n' >&2; exit 7"], Options)).

runner_scrubs_tmux_selectors_and_cleans_its_private_directory_test() ->
    Script = "test -z \"${TMUX+x}${TMUX_PANE+x}${LIBTMUX_SOCKET+x}"
             "${LIBTMUX_SOCKET_PATH+x}\" && "
             "test \"$LIBTMUX_TEST_TMUX\" = /selected/tmux && "
             "test \"$TMUX_TMPDIR\" = \"$LIBTMUX_TEST_SANDBOX\" && "
             "test -d \"$TMUX_TMPDIR\" && "
             "test \"$(stat -c %a \"$TMUX_TMPDIR\")\" = 700 && "
             "printf '%s\\n' \"$TMUX_TMPDIR\"",
    Environment = [{"TMUX", "outside"}, {"TMUX_PANE", "%1"},
                   {"LIBTMUX_SOCKET", "outside"}, {"LIBTMUX_SOCKET_PATH", "outside"},
                   {"LIBTMUX_TEST_TMUX", "/selected/tmux"}],
    Options = #{cwd => element(2, file:get_cwd()), env => Environment,
                timeout_ms => 1000},
    Outcome = check:runner(["sh", "-c", Script], Options),
    ?assertMatch(#{exit_status := 0, timed_out := false}, Outcome),
    Directory = string:trim(binary_to_list(maps:get(output, Outcome))),
    ?assertNotEqual([], Directory),
    ?assertNot(filelib:is_dir(Directory)).

runner_cleans_its_directory_after_failure_and_cancellation_test() ->
    Script = "printf '%s\\n' \"$TMUX_TMPDIR\"; "
             "if test \"$1\" = failure; then exit 7; else exec cat; fi",
    Options = #{cwd => element(2, file:get_cwd()), env => [], timeout_ms => 200},
    lists:foreach(fun(Mode) ->
        Outcome = check:runner(["sh", "-c", Script, "sandbox", Mode], Options),
        case Mode of
            "failure" -> ?assertMatch(#{exit_status := 7, timed_out := false}, Outcome);
            "cancel" -> ?assertMatch(#{timed_out := true}, Outcome)
        end,
        Directory = string:trim(binary_to_list(maps:get(output, Outcome))),
        ?assertNotEqual([], Directory),
        ?assertNot(filelib:is_dir(Directory))
    end, ["failure", "cancel"]).

%% `timeout` keeps the command alive as the parent of `setsid`, which moves
%% `sleep` into a new session: a signal to the command's process group never
%% reaches it.
overrun_kills_a_descendant_in_its_own_session_test() ->
    case {os:find_executable("timeout"), os:find_executable("setsid")} of
        {false, _} -> ok;
        {_, false} -> ok;
        _ ->
            % Only this invocation may match the cleanup scan's sleep argument.
            Seconds = lists:flatten(io_lib:format("299.~10..0B~B", [
                list_to_integer(os:getpid()), erlang:unique_integer([positive])])),
            Options = #{cwd => element(2, file:get_cwd()), env => [], timeout_ms => 500},
            try check:runner(["timeout", "299", "setsid", "sleep", Seconds], Options) of
                Outcome ->
                    ?assertMatch(#{timed_out := true}, Outcome),
                    ?assertEqual([], sleepers(Seconds))
            after
                lists:foreach(fun(Pid) -> os:cmd("kill -KILL " ++ Pid) end, sleepers(Seconds))
            end
    end.

%% Process IDs whose command line is `sleep Seconds`, with or without a parent.
sleepers(Seconds) ->
    Needle = <<"sleep", 0, (list_to_binary(Seconds))/binary, 0>>,
    [filename:basename(filename:dirname(Path)) ||
        Path <- filelib:wildcard("/proc/[0-9]*/cmdline"),
        {ok, Text} <- [file:read_file(Path)],
        binary:match(Text, Needle) =/= nomatch].

outcome(Status, TimedOut) ->
    #{exit_status => Status, seconds => 0.0, timed_out => TimedOut, output => <<>>}.
