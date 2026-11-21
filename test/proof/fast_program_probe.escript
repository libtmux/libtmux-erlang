-mode(compile).

main([Executable, Version]) ->
    Build = filename:absname("_build/test"),
    ok = code:add_pathsa([filename:join(Build, Path) || Path <-
        ["lib/libtmux_erlang/ebin", "extras/test", "extras/scripts"]]),
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Cases = tmux_test_sandbox:with(fun() ->
        [run(list_to_binary(Executable), Kind) || Kind <- [literal_argv, final_screen]]
    end),
    Output = json:format(#{version => list_to_binary(Version), cases => Cases,
                          sandbox_retired => true}),
    ok = filelib:ensure_dir("_build/checks/fast-program-probe.json"),
    ok = file:write_file("_build/checks/fast-program-probe.json", Output),
    io:put_chars(Output),
    halt(case lists:all(fun(#{result := Result}) -> Result =:= 'PASS' end, Cases) of
        true -> 0;
        false -> 1
    end).

run(Executable, Kind) ->
    Started = erlang:monotonic_time(microsecond),
    try tmux_test_fixture:with_server(Executable, fun(Server, Fixture) ->
        workload(Server, Fixture, Kind)
    end) of
        Result -> Result#{case_name => Kind, result => 'PASS', fixture_retired => true,
            seconds => (erlang:monotonic_time(microsecond) - Started) / 1000000}
    catch Class:Error:Stack ->
        #{case_name => Kind, result => 'FAIL',
          failure => iolist_to_binary(io_lib:format("~tp", [{Class, Error, Stack}]))}
    end.

workload(Server, Fixture, Kind) ->
    {ok, _} = tmux_session:create(Server,
        #{name => <<"program-proof">>, width => 80, height => 20,
          launch => #{argv => [<<"/bin/cat">>]}}),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    [Window] = tmux_snapshot:windows(Snapshot),
    [Parent] = tmux_snapshot:panes(Snapshot),
    ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Parent)),
    {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
    {ok, _} = tmux_option:set(Window, <<"remain-on-exit-format">>, <<>>),
    {Args, Status, Expected} = program(Kind),
    {ok, Pane} = tmux_pane:split(Window, #{launch => #{argv => Args}}),
    {ok, #{exit := {status, Status}, pane := Dead}} =
        tmux_pane:wait_exit(Pane, #{deadline_ms => 900}),
    Id = tmux_model:get(id, Dead),
    {AtExit, History} = dead_time(Server, Id, 400),
    ExitOnly = capture(Server, Id, 16384),
    {Published, Attempts, FinalHistory} = await_screen(Server, Id,
        erlang:monotonic_time(millisecond) + 500, 1, {AtExit, History}),
    Screen = capture(Server, Id, 16384),
    true = lists:all(fun(Line) -> binary:match(Screen, Line) =/= nomatch end, Expected),
    {error, #{code := output_limit, cleanup := complete}} =
        tmux_target:run(Server, <<"capture-pane">>,
            [<<"-p">>, <<"-S">>, <<"-100">>, <<"-t">>, Id],
            #{max_stdout => 4, deadline_ms => 500}),
    #{status => Status, pane_id => Id, history_rows => FinalHistory,
      screen_bytes => byte_size(Screen), matched => Expected, publication => Published,
      publication_attempts => Attempts, marker_already_published => AtExit =/= <<>>,
      same_at_exit => ExitOnly =:= Screen}.

program(literal_argv) ->
    Literal = <<"literal #{pane_id}; value">>,
    {[<<"/usr/bin/printf">>, <<"<%s>\\n">>, <<>>, Literal], 0,
     [<<"<>\n">>, <<"<", Literal/binary, ">\n">>]};
program(final_screen) ->
    Out = <<(binary:copy(<<"0123456789abcdefghijklmnopqrstuvwxyz0123456789\n">>, 100))/binary,
        "stdout-end\n">>,
    Err = <<"stderr-end\n">>,
    {Child, Args} = tmux_test_child:command(<<"write">>, [Out, Err, <<"23">>]),
    {[Child | Args], 23, [<<"stdout-end\nstderr-end\n">>]}.

dead_time(Server, Id, Remaining) ->
    Format = <<"#{pane_id}\t#{pane_dead_time}\t#{history_size}">>,
    {ok, #{stdout := Bytes}} = tmux_target:run(Server, <<"display-message">>,
        [<<"-p">>, <<"-t">>, Id, <<"-F">>, Format],
        #{deadline_ms => Remaining, max_stdout => 96}),
    [Id, Time, Rows] = binary:split(string:trim(Bytes, trailing, "\n"), <<"\t">>, [global]),
    {Time, binary_to_integer(Rows)}.

await_screen(_, _, _, Attempts, {Time, History}) when Time =/= <<>> ->
    {Time, Attempts, History};
await_screen(Server, Id, Deadline, Attempts, {<<>>, _}) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    true = Left > 0,
    receive after min(Left, 10) -> ok end,
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    true = Remaining > 0,
    Next = dead_time(Server, Id, Remaining),
    await_screen(Server, Id, Deadline, Attempts + 1, Next).

capture(Server, Id, Limit) ->
    {ok, #{stdout := Screen}} = tmux_target:run(Server, <<"capture-pane">>,
        [<<"-p">>, <<"-S">>, <<"-100">>, <<"-t">>, Id],
        #{max_stdout => Limit, deadline_ms => 500}),
    Screen.
