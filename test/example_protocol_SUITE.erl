-module(example_protocol_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         reply_allows_completion/1, unexpected_reply_fails/1, missing_reply_fails/1,
         failed_run_replaces_success/1, interrupted_run_leaves_running/1,
         unencodable_result_fails/1]).

%% Outer: the terminal job runs on a PTY and the example runner is a subprocess.
%% erlexec, a test-profile dependency, supplies the PTY.
all() -> [reply_allows_completion, unexpected_reply_fails, missing_reply_fails,
          failed_run_replaces_success, interrupted_run_leaves_running,
          unencodable_result_fails].

%% Bound for VM start-up on a loaded host. Every wait ends on its event, not on this bound.
-define(START_MS, 10000).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlexec),
    Root = checkout(code:lib_dir(libtmux_erlang)),
    Escript = os:find_executable("escript"),
    true = is_list(Escript),
    [{root, Root}, {escript, Escript} | Config].

end_per_suite(_) -> ok = application:stop(erlexec).

%% The Common Test node does not run in the checkout; find it above the build tree.
checkout("/") -> ct:fail(checkout_not_found);
checkout(Directory) ->
    case filelib:is_file(filename:join(Directory, "scripts/check/run_examples.escript")) of
        true -> Directory;
        false -> checkout(filename:dirname(Directory))
    end.

reply_allows_completion(Config) ->
    {0, <<>>} = job(Config, <<"\e[0n">>).

unexpected_reply_fails(Config) ->
    {1, Message} = job(Config, <<"nope">>),
    {_, _} = binary:match(Message, <<"unexpected terminal acknowledgement">>).

missing_reply_fails(Config) ->
    {1, Message} = job(Config, none),
    {_, _} = binary:match(Message, <<"did not acknowledge output">>).

%% Runs the job on a 24x80 PTY and answers its request like a terminal parser.
%% Returns the exit code and what the job wrote after the request.
job(Config, Reply) ->
    Escript = proplists:get_value(escript, Config),
    Job = filename:join(proplists:get_value(root, Config), "examples/terminal_job.erl"),
    {ok, _, OsPid} = exec:run([Escript, Job],
        [stdin, stdout, {stderr, stdout}, pty, {winsz, {24, 80}}, monitor,
         {env, [{"TERM", "xterm-256color"}, {"TMUX", false}, {"TMUX_PANE", false}]}]),
    try
        Request = <<"build complete\r\n\e[5n">>,
        Request = request(OsPid, <<>>, deadline(?START_MS)),
        receive {'DOWN', OsPid, process, _, Early} ->
            ct:fail({completed_without_acknowledgement, Early})
        after 0 -> ok
        end,
        ok = case Reply of none -> ok; _ -> exec:send(OsPid, Reply) end,
        Status = exit_status(OsPid, deadline(?START_MS)),
        {Status, drain(stdout, OsPid, <<>>)}
    after
        reap(OsPid)
    end.

request(OsPid, Seen, Deadline) ->
    case binary:longest_common_suffix([Seen, <<"\e[5n">>]) of
        4 -> Seen;
        _ ->
            receive
                {stdout, OsPid, Bytes} -> request(OsPid, <<Seen/binary, Bytes/binary>>, Deadline);
                {'DOWN', OsPid, process, _, Reason} -> ct:fail({job_exited, Reason, Seen})
            after remaining(Deadline) -> ct:fail({no_request, Seen})
            end
    end.

exit_status(OsPid, Deadline) ->
    receive
        {'DOWN', OsPid, process, _, normal} -> 0;
        {'DOWN', OsPid, process, _, {exit_status, Raw}} -> {status, Code} = exec:status(Raw), Code
    after remaining(Deadline) -> ct:fail(job_did_not_exit)
    end.

drain(Stream, OsPid, Seen) ->
    receive {Stream, OsPid, Bytes} -> drain(Stream, OsPid, <<Seen/binary, Bytes/binary>>)
    after 0 -> Seen
    end.

%% Prove the OS process is gone, killing it first when a failed check left it running.
reap(OsPid) ->
    case exec:pid(OsPid) of
        Pid when is_pid(Pid) ->
            Monitor = erlang:monitor(process, Pid),
            _ = exec:stop(OsPid),
            receive {'DOWN', Monitor, process, Pid, _} -> ok
            after 6000 -> ct:fail({os_process_survived, OsPid})
            end;
        _ -> ok
    end,
    false = filelib:is_file("/proc/" ++ integer_to_list(OsPid) ++ "/stat").

failed_run_replaces_success(Config) ->
    Project = project(Config, failed_run_replaces_success),
    {Status, _, Error} = run_examples(Config, Project),
    true = Status =/= 0,
    {_, _} = binary:match(Error, <<"enoent">>),
    #{<<"result">> := <<"FAIL">>} = Current = receipt(Project),
    error = maps:find(<<"old">>, Current).

interrupted_run_leaves_running(Config) ->
    Project = project(Config, interrupted_run_leaves_running),
    prepare_filter(Config, Project,
        "io:format(\"ready ~s~n\", [code:which(?MODULE)]), receive stop -> #{} end"),
    {ok, _, OsPid} = start_examples(Config, Project),
    try
        <<"ready ", Path/binary>> = ready_line(OsPid, <<>>, deadline(?START_MS)),
        Scratch = unicode:characters_to_binary(filename:join(Project, "scratch")),
        Directory = filename:dirname(Path),
        <<"filter_demo.beam">> = filename:basename(Path),
        Scratch = filename:dirname(Directory),
        {match, _} = re:run(filename:basename(Directory), "^ltm-examples-[0-9a-f]{20}$"),
        #{<<"result">> := <<"RUNNING">>} = receipt(Project),
        ok = exec:kill(OsPid, sigkill),
        receive {'DOWN', OsPid, process, _, {exit_status, _}} -> ok
        after ?START_MS -> ct:fail(runner_survived_kill)
        end,
        #{<<"result">> := After} = receipt(Project),
        true = After =/= <<"PASS">>
    after
        reap(OsPid)
    end.

unencodable_result_fails(Config) ->
    Project = project(Config, unencodable_result_fails),
    prepare_filter(Config, Project, "make_ref()"),
    {Status, _, _} = run_examples(Config, Project),
    true = Status =/= 0,
    #{<<"result">> := <<"FAIL">>} = receipt(Project).

%% A scratch checkout holding the runner and an old success receipt.
project(Config, Case) ->
    Root = proplists:get_value(root, Config),
    Project = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(Case)),
    lists:foreach(fun(Name) -> ok = filelib:ensure_path(filename:join(Project, Name)) end,
                  ["test", "examples", "_build/checks", "scratch", "scripts/check"]),
    {ok, _} = file:copy(filename:join(Root, "scripts/check/run_examples.escript"),
                        filename:join(Project, "scripts/check/run_examples.escript")),
    {ok, _} = file:copy(filename:join(Root, "scripts/check/tmux_test_sandbox.erl"),
                        filename:join(Project, "scripts/check/tmux_test_sandbox.erl")),
    ok = file:write_file(filename:join(Project, "_build/checks/examples.json"),
                         json:encode(#{result => <<"PASS">>, old => true})),
    Project.

prepare_filter(Config, Project, Body) ->
    {ok, _} = file:copy(filename:join(proplists:get_value(root, Config),
                                      "test/tmux_test_fixture.erl"),
                        filename:join(Project, "test/tmux_test_fixture.erl")),
    ok = file:write_file(filename:join(Project, "examples/filter_demo.erl"),
        ["-module(filter_demo).\n-export([run/0]).\nrun() -> ", Body, ".\n"]).

receipt(Project) ->
    {ok, Bytes} = file:read_file(filename:join(Project, "_build/checks/examples.json")),
    json:decode(Bytes).

start_examples(Config, Project) ->
    Runner = filename:join(Project, "scripts/check/run_examples.escript"),
    Ebin = filename:join(code:lib_dir(libtmux_erlang), "ebin"),
    exec:run([proplists:get_value(escript, Config), Runner, "--ebin", Ebin, "filter"],
        [stdout, stderr, monitor, {cd, Project},
         {env, [{"TMPDIR", filename:join(Project, "scratch")}, {"LIBTMUX_TEST_TMUX", false},
                {"TMUX", false}, {"TMUX_PANE", false}]}]).

run_examples(Config, Project) ->
    {ok, _, OsPid} = start_examples(Config, Project),
    try
        Status = exit_status(OsPid, deadline(?START_MS)),
        {Status, drain(stdout, OsPid, <<>>), drain(stderr, OsPid, <<>>)}
    after
        reap(OsPid)
    end.

ready_line(OsPid, Seen, Deadline) ->
    case binary:split(Seen, <<"\n">>) of
        [Line, _] -> Line;
        [_] ->
            receive
                {stdout, OsPid, Bytes} ->
                    ready_line(OsPid, <<Seen/binary, Bytes/binary>>, Deadline);
                {'DOWN', OsPid, process, _, Reason} -> ct:fail({runner_exited, Reason, Seen})
            after remaining(Deadline) -> ct:fail({no_ready_line, Seen})
            end
    end.

deadline(Milliseconds) -> erlang:monotonic_time(millisecond) + Milliseconds.
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).
