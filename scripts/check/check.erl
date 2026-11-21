%% Run bounded development checks and retain command-level evidence.
%% Usage: escript scripts/check/check.erl inner --module MODULE
%%        escript scripts/check/check.erl mid
%%        escript scripts/check/check.erl outer
%%
%% Each tier runs its commands in order under one time budget, keeps every
%% command's output in _build/checks/<tier>-<n>.log and writes a receipt to
%% _build/checks/<tier>.json. A failed or overrunning command ends the loop.
%% The sandbox helper is loaded from source before the library is compiled.
-module(check).
-mode(compile).
-export([main/1, plan/2, budget/1, run/3, runner/2, passed/3]).
-export_type([command/0, outcome/0, tier/0]).

%% Set in every command's environment so its descendants can be found.
-define(RUN_VARIABLE, "LIBTMUX_CHECK_RUN").

-type tier() :: inner | mid | outer.
-type command() :: [string()].
-type outcome() :: #{exit_status := integer(), seconds := float(), timed_out := boolean(),
                     output := binary()}.

-spec main([string()]) -> no_return().
main(Arguments) ->
    {Tier, Module} = parse(Arguments),
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = file:set_cwd(Root),
    ok = load_sandbox(Root),
    Output = filename:join(Root, "_build/checks"),
    ok = filelib:ensure_path(Output),
    Environment = [{"ERL_FLAGS", case os:getenv("ERL_FLAGS") of false -> "+S 4:4"; Flags -> Flags end}],
    Prefix = case os:getenv("GITHUB_ACTIONS") of
        "true" -> [];
        _ -> ["mise", "exec", "--"]
    end,
    Started = erlang:monotonic_time(millisecond),
    Runner = fun(Command, RemainingMs) ->
        runner(Prefix ++ Command, #{cwd => Root, env => Environment, timeout_ms => RemainingMs})
    end,
    {Failed, Results} = run(plan(Tier, Module), budget(Tier), Runner),
    Seconds = (erlang:monotonic_time(millisecond) - Started) / 1000,
    Written = [record(Tier, Output, Prefix, N, R) || {N, R} <- lists:enumerate(Results)],
    Passed = passed(Failed, Seconds, Tier),
    Receipt = #{tier => atom_to_binary(Tier), result => verdict(Passed),
                budget_seconds => budget(Tier), dispatch_seconds => Seconds,
                runtime_flags => list_to_binary(proplists:get_value("ERL_FLAGS", Environment)),
                commands => Written,
                scope => <<"Currently implemented checks; not the complete epic matrix">>},
    ok = file:write_file(filename:join(Output, atom_to_list(Tier) ++ ".json"),
                         [json:format(Receipt), $\n]),
    halt(case Passed of true -> 0; false -> 1 end).

%% A loop passes when no command failed and it finished inside its budget.
-spec passed(boolean(), number(), tier()) -> boolean().
passed(Failed, Seconds, Tier) -> not Failed andalso Seconds < budget(Tier).

parse(["inner", "--module", Module]) -> {inner, Module};
parse(["inner" | _]) -> usage("inner requires --module; use mid for the full unit suite");
parse(["mid"]) -> {mid, none};
parse(["outer"]) -> {outer, none};
parse(_) -> usage("usage: check.erl inner --module MODULE | mid | outer").

-spec usage(string()) -> no_return().
usage(Message) ->
    io:format(standard_error, "~s~n", [Message]),
    halt(2).

-spec budget(tier()) -> pos_integer().
budget(inner) -> 5;
budget(mid) -> 30;
budget(outer) -> 300.

%% The commands of each tier. Scripts run after the library is compiled.
-spec plan(tier(), string() | none) -> [command()].
plan(inner, Module) ->
    [["rebar3", "eunit", "--module", Module]];
plan(mid, _) ->
    [["rebar3", "compile"],
     ["escript", "tools/generate_schema.escript", "--check"],
     ["escript", "scripts/generate/generate_options.erl", "--check"],
     ["escript", "scripts/regex/generate_fixture.erl", "--check"],
     ["rebar3", "eunit"],
     ["escript", "tools/generate_reference.escript", "--test", "--check"],
     ["escript", "tools/check_api_docs.escript", "--test"],
     ["escript", "scripts/docs/check_docs.erl"],
     ["escript", "scripts/generate/generate_commands.erl", "--check"],
     ["git", "diff", "--check"]];
plan(outer, _) ->
    [["rebar3", "compile"],
     ["rebar3", "dialyzer"],
     ["rebar3", "ct"],
     ["escript", "tools/run_examples.escript"],
     ["escript", "scripts/docs/check_docs.erl", "--examples-receipt", "_build/checks/examples.json"],
     ["escript", "scripts/package/check_package.erl", "--dialyzer"]].

%% Run commands in order within Budget seconds. Returns whether the loop
%% failed and one result per command run: {Command, Outcome} or an overrun.
-spec run([command()], non_neg_integer(), fun((command(), pos_integer()) -> outcome())) ->
    {boolean(), [{command(), outcome() | budget_exceeded}]}.
run(Commands, Budget, Runner) ->
    Started = erlang:monotonic_time(millisecond),
    run(Commands, Budget * 1000, Started, Runner, []).

run([], _, _, _, Acc) -> {false, lists:reverse(Acc)};
run([Command | Rest], Budget, Started, Runner, Acc) ->
    Remaining = Budget - (erlang:monotonic_time(millisecond) - Started),
    case Remaining =< 0 of
        true -> {true, lists:reverse([{Command, budget_exceeded} | Acc])};
        false ->
            #{exit_status := Status, timed_out := TimedOut} = Outcome = Runner(Command, Remaining),
            Result = [{Command, Outcome} | Acc],
            case Status =:= 0 andalso not TimedOut of
                true -> run(Rest, Budget, Started, Runner, Result);
                false -> {true, lists:reverse(Result)}
            end
    end.

%% Run one command. When it overruns Milliseconds, kill it and everything it
%% started, including processes that left its process group or session.
-spec runner(command(), #{cwd := file:filename(), env := [{string(), string()}],
                          timeout_ms := integer()}) -> outcome().
runner([Program | Arguments], #{cwd := Root, env := Environment, timeout_ms := Milliseconds}) ->
    Started = erlang:monotonic_time(millisecond),
    Run = integer_to_list(erlang:unique_integer([positive])) ++ "-" ++ os:getpid(),
    Result = tmux_test_sandbox:with(Environment, fun(Sandbox) ->
        Port = open_port({spawn_executable, os:find_executable(Program)},
            [binary, exit_status, stderr_to_stdout, {cd, Root},
             {env, [{?RUN_VARIABLE, Run} | Sandbox]}, {args, Arguments}]),
        {Status, Output, TimedOut} = collect(Port, Started + Milliseconds, Run, <<>>),
        #{exit_status => Status, output => Output, timed_out => TimedOut}
    end),
    Seconds = (erlang:monotonic_time(millisecond) - Started) / 1000,
    Result#{seconds => Seconds}.

load_sandbox(Root) ->
    Path = filename:join([Root, "scripts", "check", "tmux_test_sandbox.erl"]),
    {ok, tmux_test_sandbox, Beam} = compile:file(Path, [binary, report_errors, report_warnings]),
    {module, tmux_test_sandbox} = code:load_binary(tmux_test_sandbox, Path, Beam),
    ok.

collect(Port, Deadline, Run, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} -> collect(Port, Deadline, Run, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc, false}
    after Remaining ->
        {os_pid, OsPid} = erlang:port_info(Port, os_pid),
        kill_run(Run, OsPid),
        {Status, Rest} = drain(Port, Acc),
        {Status, Rest, true}
    end.

drain(Port, Acc) ->
    receive
        {Port, {data, Data}} -> drain(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
    end.

%% Every process the command started carries ?RUN_VARIABLE in its environment,
%% whatever its parent, group or session. Kill them, then rescan until none
%% is left, because a process may fork between a scan and its kill. Without
%% /proc only the command itself is killed.
kill_run(Run, OsPid) ->
    kill([integer_to_list(OsPid) | marked(Run)]),
    kill_marked(Run, 100).

kill_marked(_, 0) -> ok;
kill_marked(Run, Left) ->
    case marked(Run) of
        [] -> ok;
        Pids ->
            kill(Pids),
            receive after 10 -> kill_marked(Run, Left - 1) end
    end.

kill(Pids) ->
    Port = open_port({spawn_executable, os:find_executable("kill")},
                     [exit_status, {args, ["-s", "KILL" | Pids]}]),
    receive {Port, {exit_status, _}} -> ok end.

%% Process IDs, as strings, whose environment names this run.
marked(Run) ->
    Entry = <<0, ?RUN_VARIABLE, $=, (list_to_binary(Run))/binary, 0>>,
    case file:list_dir("/proc") of
        {ok, Names} ->
            [Name || Name <- Names, lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Name),
                     {ok, Environment} <- [file:read_file(filename:join(["/proc", Name, "environ"]))],
                     binary:match(<<0, Environment/binary>>, Entry) =/= nomatch];
        {error, _} -> []
    end.

%% Keep the output, print the verdict line and build the receipt entry.
record(Tier, Output, Prefix, Number, {Command, budget_exceeded}) ->
    _ = {Tier, Output, Prefix, Number, Command},
    #{result => <<"FAIL">>, reason => <<"loop_budget_exceeded">>};
record(Tier, Output, Prefix, Number, {Command, Outcome}) ->
    #{exit_status := Status, seconds := Seconds, timed_out := TimedOut, output := Text} = Outcome,
    Log = filename:join(Output, atom_to_list(Tier) ++ "-" ++ integer_to_list(Number) ++ ".log"),
    ok = file:write_file(Log, Text),
    Passed = Status =:= 0 andalso not TimedOut,
    Line = lists:join(" ", Prefix ++ Command),
    io:format("~s ~.3fs ~s~n", [verdict(Passed), Seconds, Line]),
    Passed orelse io:format("~ts~n", [Text]),
    #{command => [list_to_binary(Part) || Part <- Prefix ++ Command],
      exit_status => Status, seconds => Seconds, result => verdict(Passed),
      timed_out => TimedOut, log => list_to_binary(filename:join("_build/checks", filename:basename(Log)))}.

verdict(true) -> <<"PASS">>;
verdict(false) -> <<"FAIL">>.
