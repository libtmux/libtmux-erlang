%% Run bounded development checks and retain command-level evidence.
%% Usage: escript scripts/check/check.erl inner --module MODULE
%%        escript scripts/check/check.erl mid
%%        escript scripts/check/check.erl outer
%%
%% Each tier runs its commands in order under one time budget, keeps every
%% command's output in _build/checks/<tier>-<n>.log and writes a receipt to
%% _build/checks/<tier>.json. A failed or overrunning command ends the loop.
%% Self-contained: it runs before the library is compiled, so it uses no
%% helper modules.
-module(check).
-mode(compile).
-export([main/1, plan/2, budget/1, run/3, runner/2]).
-export_type([command/0, outcome/0, tier/0]).

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
    Over = Failed orelse Seconds >= budget(Tier),
    Receipt = #{tier => atom_to_binary(Tier), result => verdict(Over),
                budget_seconds => budget(Tier), dispatch_seconds => Seconds,
                runtime_flags => list_to_binary(proplists:get_value("ERL_FLAGS", Environment)),
                commands => Written,
                scope => <<"Currently implemented checks; not the complete epic matrix">>},
    ok = file:write_file(filename:join(Output, atom_to_list(Tier) ++ ".json"),
                         [json:format(Receipt), $\n]),
    halt(case Over of true -> 1; false -> 0 end).

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
     ["python3", "tools/check_example_width.py"],
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

%% Run one command under `timeout`, which kills its whole process group.
-spec runner(command(), #{cwd := file:filename(), env := [{string(), string()}],
                          timeout_ms := integer()}) -> outcome().
runner([Program | Arguments], #{cwd := Root, env := Environment, timeout_ms := Milliseconds}) ->
    Started = erlang:monotonic_time(millisecond),
    Limit = io_lib:format("~.3f", [Milliseconds / 1000]),
    Port = open_port({spawn_executable, os:find_executable("timeout")},
        [binary, exit_status, stderr_to_stdout, {cd, Root}, {env, Environment},
         {args, ["--signal=KILL", Limit, os:find_executable(Program) | Arguments]}]),
    {Status, Output} = collect(Port, <<>>),
    Seconds = (erlang:monotonic_time(millisecond) - Started) / 1000,
    #{exit_status => Status, seconds => Seconds, output => Output,
      timed_out => Status =:= 137 andalso Seconds * 1000 >= Milliseconds - 50}.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
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
