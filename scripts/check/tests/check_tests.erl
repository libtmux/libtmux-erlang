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
                   ["escript", "tools/run_examples.escript"]]).

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

outcome(Status, TimedOut) ->
    #{exit_status => Status, seconds => 0.0, timed_out => TimedOut, output => <<>>}.
