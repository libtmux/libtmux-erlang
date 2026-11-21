-mode(compile).

main([Executable, Version]) ->
    Build = filename:absname("_build/test"),
    ok = code:add_pathsa([filename:join(Build, Path) || Path <-
        ["lib/libtmux_erlang/ebin", "extras/test", "extras/scripts"]]),
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Cases = tmux_test_sandbox:with(fun() ->
        [run(Executable, list_to_binary(Version), Method) || Method <- [stdout, buffer_file]]
    end),
    Equal = same_output(Cases),
    Receipt = "_build/checks/pane-text-probe.json",
    ok = filelib:ensure_dir(Receipt),
    Output = json:format(#{cases => Cases, same_output => Equal, sandbox_retired => true}),
    ok = file:write_file(Receipt, Output),
    io:put_chars(Output),
    halt(case Equal of true -> 0; false -> 1 end).

same_output([#{result := 'PASS', entry_capture := Before, observed := Bytes},
             #{result := 'PASS', entry_capture := Before, observed := Bytes}]) -> true;
same_output(_) -> false.

run(Executable, Version, Method) ->
    try
        {Microseconds, Result} = timer:tc(fun() ->
            tmux_test_fixture:with_server(list_to_binary(Executable), fun(Server, Fixture) -> workload(Server, Fixture, Method) end)
        end),
        Result#{version => Version, method => Method, fixture_retired => true, result => 'PASS',
                seconds => Microseconds / 1000000}
    catch Class:Failure:Stack ->
        #{version => Version, method => Method, result => 'FAIL',
          failure => iolist_to_binary(io_lib:format("~tp", [{Class, Failure, Stack}]))}
    end.

workload(Server, Fixture, Method) ->
    Cat = #{argv => [<<"/bin/cat">>]},
    {ok, _} = tmux_session:create(Server,
        #{name => <<"visibility">>, width => 70, height => 8, launch => Cat}),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    [Pane] = tmux_snapshot:panes(Snapshot),
    FirstPid = tmux_model:get(pid, Pane),
    ok = tmux_test_fixture:track_process(Fixture, FirstPid),
    {ok, Incarnation} = tmux_identity:observe(FirstPid),
    #{directory := Directory} = tmux_test_fixture:info(Fixture),
    Read = fun(Due) -> read(Method, Server, Pane, Directory, 4096, Due) end,
    Needle = <<"visible-needle">>,
    {Observer, Monitor, Before} = start_observer(Read, Needle, 800),
    nomatch = binary:match(Before, Needle),
    {ok, _} = tmux_pane:send_text(Pane, Needle),
    {found, Observed, Count} = outcome(Observer, Monitor),
    {_, _} = binary:match(Observed, Needle),
    {ok, Observed} = guarded_read(Incarnation, FirstPid, fun() -> Read(500) end),
    {EntryObserver, EntryMonitor, Observed} = start_observer(Read, Needle, 800),
    {found, Observed, 1} = outcome(EntryObserver, EntryMonitor),
    {CancelObserver, CancelMonitor, _} = start_observer(Read, <<"never-visible">>, 800),
    CancelObserver ! cancel,
    {cancelled, _, _} = outcome(CancelObserver, CancelMonitor),
    {DeadlineObserver, DeadlineMonitor, _} = start_observer(Read, <<"never-visible">>, 200),
    {deadline, _, _} = outcome(DeadlineObserver, DeadlineMonitor),
    complete = cancel_admitted_capture(Server, Fixture, Pane),
    {ok, _} = tmux_pane:respawn(Pane, #{force => true, launch => Cat}),
    {ok, Replacement} = tmux_pane:get(Server, tmux_model:get(id, Pane)),
    NewPid = tmux_model:get(pid, Replacement),
    true = is_integer(NewPid) andalso NewPid =/= FirstPid,
    ok = tmux_test_fixture:track_process(Fixture, NewPid),
    {ok, AfterRespawn} = Read(500),
    nomatch = binary:match(AfterRespawn, Needle),
    {error, stale_pane} = guarded_read(Incarnation, FirstPid,
                                       fun() -> error(capture_after_respawn) end),
    {error, #{code := output_limit}} =
        read(Method, Server, Pane, Directory, 0, 500),
    {ok, []} = tmux_buffer:list(Server),
    {ok, ["s"]} = file:list_dir(Directory),
    #{entry_capture => Before, observed => Observed, issued_captures => Count,
      idle_cancel => complete, admitted_cancel => complete, deadline => complete,
      same_id_respawn_readable => true, generation_guard => refused_before_capture,
      buffer_cleanup => complete}.

guarded_read(Incarnation, Pid, Read) ->
    case tmux_identity:check(Incarnation, Pid) of
        ok ->
            Result = Read(),
            case tmux_identity:check(Incarnation, Pid) of
                ok -> Result;
                {error, _} -> {error, stale_pane}
            end;
        {error, _} -> {error, stale_pane}
    end.

cancel_admitted_capture(Server, Fixture, Pane) ->
    Ready = <<"visibility-read-ready">>,
    Blocked = <<"visibility-read-parked">>,
    {ok, Listen} = tmux_test_fixture:start_command(Fixture, [<<"wait-for">>, Ready]),
    try
        {ok, Signal} = tmux_command:wait_for(Ready, signal),
        {ok, Park} = tmux_command:wait_for(Blocked, wait),
        Id = tmux_model:get(id, Pane),
        {ok, Capture} = tmux_command:raw(<<"capture-pane">>, [<<"-p">>, <<"-t">>, Id]),
        {ok, Sequence} = tmux_command:sequence([Signal, Park, Capture]),
        {ok, Operation} = tmux_operation:start(Server, Sequence, #{deadline_ms => 800}),
        {ok, #{exit_status := 0, cleanup := complete}} = tmux_transport:await(Listen, 700),
        {ok, cancel_requested} = tmux_operation:cancel(Operation),
        {error, #{outcome := unknown, cleanup := complete}} =
            tmux_operation:await(Operation, 700),
        complete
    after ok = tmux_transport:close(Listen)
    end.

start_observer(Read, Needle, Milliseconds) ->
    Caller = self(),
    {Observer, Monitor} = spawn_monitor(fun() ->
        Deadline = erlang:monotonic_time(millisecond) + Milliseconds,
        {ok, First} = Read(Milliseconds),
        Caller ! {self(), ready, First},
        Caller ! {self(), done, inspect(Read, Needle, Deadline, First, 1)}
    end),
    receive
        {Observer, ready, First} -> {Observer, Monitor, First};
        {'DOWN', Monitor, process, Observer, Reason} -> error({sample, Reason})
    after 900 -> error(observer_start_timeout)
    end.

inspect(Read, Needle, Deadline, Bytes, Count) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case {Left > 0, binary:match(Bytes, Needle)} of
        {false, _} -> {deadline, Bytes, Count};
        {true, {_, _}} -> {found, Bytes, Count};
        {true, nomatch} ->
            receive cancel -> {cancelled, Bytes, Count}
            after min(12, Left) ->
                Remaining = Deadline - erlang:monotonic_time(millisecond),
                case Remaining > 0 of
                    false -> {deadline, Bytes, Count};
                    true -> case Read(Remaining) of
                        {ok, Next} -> inspect(Read, Needle, Deadline, Next, Count + 1);
                        {error, #{code := Code, cleanup := complete}}
                          when Code =:= deadline; Code =:= timeout ->
                            true = erlang:monotonic_time(millisecond) >= Deadline,
                            {deadline, Bytes, Count + 1};
                        Error -> error({capture, Error})
                    end
                end
            end
    end.

outcome(Observer, Monitor) ->
    Result = receive
        {Observer, done, Outcome} -> Outcome;
        {'DOWN', Monitor, process, Observer, Reason} -> error({observer_down, Reason})
    after 900 -> error(observer_result_timeout)
    end,
    receive {'DOWN', Monitor, process, Observer, normal} -> Result
    after 900 -> error(observer_unretired)
    end.

read(stdout, Server, Pane, _Directory, Limit, Milliseconds) ->
    Id = tmux_model:get(id, Pane),
    {ok, Command} = tmux_command:raw(<<"capture-pane">>, [<<"-p">>, <<"-t">>, Id]),
    case tmux_server:command(Server, Command,
                             #{deadline_ms => Milliseconds, max_stdout => Limit}) of
        {ok, #{stdout := Bytes}} -> {ok, Bytes};
        Error -> Error
    end;
read(buffer_file, Server, Pane, Directory, Limit, Milliseconds) ->
    Id = tmux_model:get(id, Pane),
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Name = <<"visibility-probe-", Suffix/binary>>,
    File = list_to_binary(filename:join(Directory, binary_to_list(Name))),
    {ok, Capture} = tmux_command:raw(<<"capture-pane">>,
                                     [<<"-b">>, Name, <<"-t">>, Id]),
    {ok, Save} = tmux_command:raw(<<"save-buffer">>, [<<"-b">>, Name, File]),
    {ok, Delete} = tmux_command:raw(<<"delete-buffer">>, [<<"-b">>, Name]),
    {ok, Commands} = tmux_command:sequence([Capture, Save, Delete]),
    try
        case tmux_server:command(Server, Commands,
                                #{deadline_ms => Milliseconds, max_stdout => 128}) of
            {ok, _} -> read_file(File, Limit);
            Error -> Error
        end
    after
        case file:delete(File) of ok -> ok; {error, enoent} -> ok end
    end.

read_file(File, Limit) ->
    {ok, Device} = file:open(File, [read, raw, binary]),
    try
        case file:read(Device, Limit + 1) of
            {ok, Bytes} when byte_size(Bytes) =< Limit -> {ok, Bytes};
            {ok, _} -> {error, #{code => output_limit}};
            eof -> {ok, <<>>};
            Error -> Error
        end
    after ok = file:close(Device)
    end.
