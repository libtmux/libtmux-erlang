-module(tmux_program_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2,
         end_per_group/2, version_gate/1, exit_results/1, capture_limits/1,
         replaced_capture/1, retained_slots/1, controller_crash/1, setup_retirement/1]).

%% Outer: the program cases exercise a private native tmux and real PTYs.
all() -> [version_gate, {group, programs}].

groups() ->
    [{programs, [], [exit_results, capture_limits, replaced_capture,
                     retained_slots, controller_crash, setup_retirement]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    Executable = list_to_binary(Path),
    {ok, #{exit_status := 0, stdout := Raw}} =
        tmux_transport:run(Executable, [<<"-V">>], #{timeout_ms => 900, max_stdout => 64}),
    {ok, Version} = tmux_version:parse(Raw),
    [{executable, Executable}, {version, Version} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

init_per_group(programs, Config) ->
    Version = proplists:get_value(version, Config),
    case tmux_capability:require(Version, program_history) of
        ok -> Config;
        {error, #{code := unsupported_capability}} -> {skip, "managed programs require tmux 3.8"}
    end.

end_per_group(_, _) -> ok.

version_gate(Config) ->
    Executable = proplists:get_value(executable, Config),
    Version = proplists:get_value(version, Config),
    {ok, Dir} = tmux_test_sandbox:fixture_directory(),
    Marker = list_to_binary(filename:join(Dir, "ran")),
    Argv = [<<"/usr/bin/touch">>, Marker],
    Before = owned_controllers(),
    {error, #{code := invalid_program_options}} =
        tmux_program:start(Executable, Argv, #{width => 65535, height => 65535}),
    case tmux_capability:require(Version, program_history) of
        ok -> ok;
        {error, #{found := Found, required := <<"3.8">>}} ->
            {error, #{code := unsupported_capability, found := Found, required := <<"3.8">>}} =
                tmux_program:run(Executable, Argv, #{})
    end,
    Before = owned_controllers(),
    {error, enoent} = file:read_file(Marker),
    ok.

owned_controllers() ->
    lists:sort([Pid || {_, Pid, worker, [tmux_owned_server]} <- supervisor:which_children(tmux_sup),
                      is_pid(Pid)]).

exit_results(Config) ->
    Executable = proplists:get_value(executable, Config),
    Code = <<"printf '<%s>\\n' \"$@\"; printf 'stderr\\n' >&2; printf '\\033['; exit 126">>,
    Argv = [<<"/bin/sh">>, <<"-c">>, Code, <<"program">>, <<>>, <<"literal; #{pane_id}">>],
    {ok, #{exit := {status, 126}, screen := Screen, pending_bytes := 2, cleanup := complete}} =
        tmux_program:run(Executable, Argv, #{}),
    {0, _} = binary:match(Screen, <<"<>\n<literal; #{pane_id}>\nstderr\n">>),
    {ok, #{exit := {signal, 9}, cleanup := complete}} =
        tmux_program:run(Executable, [<<"/bin/sh">>, <<"-c">>, <<"kill -KILL $$">>], #{}),
    {ok, Dir} = tmux_test_sandbox:fixture_directory(),
    Missing = list_to_binary(filename:join(Dir, "missing")),
    {error, #{code := program_launch_failed, stage := exec, cleanup := complete}} =
        tmux_program:run(Executable, [Missing], #{}).

capture_limits(Config) ->
    Executable = proplists:get_value(executable, Config),
    check_limit(Executable, <<"printf '%072d\\n' 1 2 3 4 5 6 7 8 9 10; exit 23">>, stdout, 23),
    check_limit(Executable, <<"printf '\\033]0;%0600d' 0; exit 24">>, pending, 24),
    {ok, #{screen := Screen, history := #{size := 2, collected := 7}, cleanup := complete}} =
        tmux_program:run(Executable, [<<"/bin/sh">>, <<"-c">>,
            <<"printf 'line %s\\n' 1 2 3 4 5 6 7 8 9 10 11 12">>],
            #{width => 20, height => 4, history_lines => 2}),
    {_, _} = binary:match(Screen, <<"line 12\n">>).

check_limit(Executable, Code, Stream, Status) ->
    {error, #{code := output_limit, stream := Stream, exit := {status, Status},
              limit := 8, encoding := terminal_bytes, history := _, cleanup := complete} = Detail} =
        tmux_program:run(Executable, [<<"/bin/sh">>, <<"-c">>, Code], #{max_bytes => 8}),
    0 = map_size(maps:with([stdout, stderr, screen], Detail)).

replaced_capture(Config) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Dir} = tmux_test_sandbox:fixture_directory(),
    Marker = list_to_binary(filename:join(Dir, "replacement")),
    Code = <<"if [ -f \"$1\" ]; then printf 'replacement\\n'; exit 0; fi; "
             "printf 'original\\n'; IFS= read -r line">>,
    Argv = [<<"/bin/sh">>, <<"-c">>, Code, <<"program">>, Marker],
    {ok, Program = {program, Controller, _, _}} = tmux_program:start(Executable, Argv, #{}),
    try
        {ok, #{state := released}} = tmux_program:await_started(Program, 900),
        #{target := #{server := Server, pane := Pane}} = sys:get_state(Controller),
        Id = tmux_model:get(id, Pane),
        {ok, _} = tmux_pane:wait_for_text(Pane, <<"original">>, #{deadline_ms => 700}),
        {OldTty, Command} = pane_launch(Server, Id),
        {match, [Gate]} = re:run(Command, <<"libtmux-program-[0-9a-f]{24}">>,
                                [{capture, first, binary}]),
        ok = file:write_file(Marker, <<>>),
        {ok, _} = tmux_target:run(Server, <<"respawn-pane">>, [<<"-k">>, <<"-t">>, Id]),
        {NewTty, Command} = pane_launch(Server, Id),
        true = OldTty =/= NewTty,
        {error, #{code := program_generation_changed, outcome := not_started}} =
            tmux_program:send_text(Program, <<"stale\n">>),
        {ok, Signal} = tmux_command:wait_for(Gate, signal),
        {ok, _} = tmux_server:command(Server, Signal, #{}),
        {error, #{code := program_generation_changed, cleanup := complete}} =
            tmux_program:await(Program, 900)
    after retire_program(Program)
    end.

pane_launch(Server, Id) ->
    Format = <<"#{pane_tty}\t#{pane_start_command_list}">>,
    {ok, #{stdout := Output}} = tmux_target:run(Server, <<"display-message">>,
        [<<"-p">>, <<"-t">>, Id, <<"-F">>, Format]),
    [Tty, Command] = binary:split(string:trim(Output, trailing, "\n"), <<"\t">>, [global]),
    {Tty, Command}.

retained_slots(Config) ->
    Executable = proplists:get_value(executable, Config),
    Argv = [<<"/usr/bin/true">>],
    Programs = [retain(Executable, Argv) || _ <- lists:seq(1, 8)],
    [First | _] = Programs,
    try
        {error, #{code := program_busy, outcome := not_started}} =
            tmux_program:start(Executable, Argv, #{}),
        ok = tmux_program:release(First),
        readmit(Executable, Argv, erlang:monotonic_time(millisecond) + 700)
    after lists:foreach(fun(Program) -> _ = tmux_program:release(Program) end, Programs)
    end.

retain(Executable, Argv) ->
    {ok, Program} = tmux_program:start(Executable, Argv, #{}),
    {ok, #{exit := {status, 0}, cleanup := complete}} = tmux_program:await(Program, 900),
    Program.

readmit(Executable, Argv, Deadline) ->
    case tmux_program:run(Executable, Argv, #{}) of
        {ok, #{exit := {status, 0}, cleanup := complete}} -> ok;
        {error, #{code := program_busy, outcome := not_started}} ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            erlang:yield(),
            readmit(Executable, Argv, Deadline)
    end.

controller_crash(Config) ->
    Executable = proplists:get_value(executable, Config),
    Argv = [<<"/usr/bin/true">>],
    Retained = [retain(Executable, Argv) || _ <- lists:seq(1, 7)],
    try check_crash_slot(Executable, Argv)
    after lists:foreach(fun(Program) -> ok = tmux_program:release(Program) end, Retained)
    end.

check_crash_slot(Executable, Argv) ->
    {ok, {program, Controller, _, _} = Program} =
        tmux_program:start(Executable, [<<"/bin/cat">>], #{}),
    {ok, #{state := released}} = tmux_program:await_started(Program, 900),
    #{version_probe := none, ownership := {owned_server, Owned, _},
      terminal_holder := {transport, Holder, _, _},
      target := #{daemon := DaemonBytes, server := Server}} = sys:get_state(Controller),
    {ok, #{endpoint := #{socket_path := Socket}}} = tmux_server:observation_context(Server),
    {Daemon, Identity} = observe(DaemonBytes),
    OwnerMonitor = monitor(process, Owned),
    HolderMonitor = monitor(process, Holder),
    {ok, Pool} = tmux_registry:program_pool(),
    ok = sys:suspend(Holder),
    try
        ok = sys:suspend(Owned),
        try
            crash_controller(Controller, Pool),
            ok = tmux_identity:check(Identity, Daemon),
            {ok, _} = file:read_link_info(Socket),
            {error, #{code := program_busy, outcome := not_started}} =
                tmux_program:start(Executable, Argv, #{}),
            ok = sys:terminate(whereis(tmux_registry), normal, 900),
            await_condition(fun() ->
                case tmux_registry:program_pool() of
                    {ok, NewPool} -> NewPool =/= Pool;
                    {error, _} -> false
                end
            end, erlang:monotonic_time(millisecond) + 700),
            {error, #{code := program_busy, outcome := not_started}} =
                tmux_program:start(Executable, Argv, #{})
        after ok = sys:resume(Owned)
        end,
        wait_exit(OwnerMonitor, Owned),
        {error, #{code := stale_server}} = tmux_identity:check(Identity, Daemon),
        {error, enoent} = file:read_link_info(Socket),
        {error, #{code := program_busy, outcome := not_started}} =
            tmux_program:start(Executable, Argv, #{})
    after ok = sys:resume(Holder)
    end,
    wait_exit(HolderMonitor, Holder),
    readmit(Executable, Argv, erlang:monotonic_time(millisecond) + 700).

crash_controller(Controller, Pool) ->
    Monitor = monitor(process, Controller),
    ok = sys:terminate(Controller, test_controller_failure, 900),
    receive {'DOWN', Monitor, process, Controller, test_controller_failure} -> ok
    after 900 -> ct:fail(controller_still_alive)
    end,
    await_condition(fun() ->
        {ok, #{operations := Count}} = tmux_admission:stats(Pool),
        Count =:= 7 andalso not lists:keymember(Controller, 2, supervisor:which_children(tmux_sup))
    end, erlang:monotonic_time(millisecond) + 700).

await_condition(Check, Deadline) ->
    case Check() of
        true -> ok;
        false ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            erlang:yield(),
            await_condition(Check, Deadline)
    end.

setup_retirement(Config) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Directory} = tmux_test_sandbox:fixture_directory(),
    Fixture = list_to_binary(filename:join(Directory, "setup")),
    Source = list_to_binary(filename:join(proplists:get_value(data_dir, Config), "setup.c")),
    Compiler = list_to_binary(os:find_executable("cc")),
    {ok, #{exit_status := 0}} = tmux_transport:run(
        Compiler, [<<"-std=c11">>, <<"-Wall">>, <<"-Wextra">>, <<"-Werror">>,
                   Source, <<"-o">>, Fixture], #{timeout_ms => 900}),
    lists:foreach(fun(Mode) -> setup_case(Executable, Fixture, Mode) end, [stop, owner_exit]),
    probe_crash(Executable, Fixture).

probe_crash(Executable, Fixture) ->
    Argv = [<<"/usr/bin/true">>],
    Retained = [retain(Executable, Argv) || _ <- lists:seq(1, 7)],
    try
        {ok, Dir} = tmux_test_sandbox:fixture_directory(),
        Fifo = list_to_binary(filename:join(Dir, "probe-ready")),
        {ok, #{exit_status := 0}} =
            tmux_transport:run(<<"/usr/bin/mkfifo">>, [Fifo], #{timeout_ms => 900}),
        Env = [{"LIBTMUX_TEST_PROGRAM_BLOCK", "-V"},
               {"LIBTMUX_TEST_PROGRAM_READY", binary_to_list(Fifo)},
               {"LIBTMUX_TEST_PROGRAM_REAL", binary_to_list(Executable)}],
        with_env(Env, fun() -> check_probe_slot(Executable, Fixture, Argv, Fifo) end)
    after lists:foreach(fun(Program) -> ok = tmux_program:release(Program) end, Retained)
    end.

check_probe_slot(Executable, Fixture, Argv, Fifo) ->
    {ok, {program, Controller, _, _}} = tmux_program:start(Fixture, Argv, #{}),
    {ok, #{exit_status := 0, stdout := Ready}} =
        tmux_transport:run(<<"/bin/cat">>, [Fifo], #{timeout_ms => 900, max_stdout => 200}),
    [Leader, Child, Leader, <<"-">>] = binary:split(string:trim(Ready), <<"\t">>, [global]),
    Identities = [observe(Pid) || Pid <- [Leader, Child]],
    #{version_probe := {transport, Probe, _}, ownership := none} = sys:get_state(Controller),
    Monitor = monitor(process, Probe),
    {ok, Pool} = tmux_registry:program_pool(),
    ok = sys:suspend(Probe),
    try
        crash_controller(Controller, Pool),
        lists:foreach(fun({Pid, Identity}) -> ok = tmux_identity:check(Identity, Pid) end, Identities),
        {error, #{code := program_busy, outcome := not_started}} =
            tmux_program:start(Executable, Argv, #{})
    after ok = sys:resume(Probe)
    end,
    wait_exit(Monitor, Probe),
    lists:foreach(fun({Pid, Identity}) ->
        {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid)
    end, Identities),
    readmit(Executable, Argv, erlang:monotonic_time(millisecond) + 700).

setup_case(Executable, Fixture, Mode) ->
    {ok, Dir} = tmux_test_sandbox:fixture_directory(),
    Fifo = list_to_binary(filename:join(Dir, "setup-ready")),
    Marker = list_to_binary(filename:join(Dir, "application-ran")),
    {ok, #{exit_status := 0}} =
        tmux_transport:run(<<"/usr/bin/mkfifo">>, [Fifo], #{timeout_ms => 900}),
    Env = [{"LIBTMUX_TEST_PROGRAM_BLOCK", "new-session"},
           {"LIBTMUX_TEST_PROGRAM_REAL", binary_to_list(Executable)},
           {"LIBTMUX_TEST_PROGRAM_READY", binary_to_list(Fifo)}],
    with_env(Env, fun() -> await_setup(Fixture, Mode, Fifo, Marker) end).

await_setup(Fixture, Mode, Fifo, Marker) ->
    Caller = self(),
    {Owner, OwnerMonitor} = spawn_monitor(fun() ->
        {ok, Program} = tmux_program:start(Fixture, [<<"/usr/bin/touch">>, Marker], #{}),
        Caller ! {setup, self(), Program},
        receive finish -> ok end
    end),
    try
        receive
            {setup, Owner, Program} -> stop_setup(Program, Owner, Mode, Fifo, Marker);
            {'DOWN', OwnerMonitor, process, Owner, Reason} -> ct:fail({setup_failed, Reason})
        after 900 -> ct:fail(setup_timeout)
        end,
        wait_exit(OwnerMonitor, Owner)
    after Owner ! finish
    end.

stop_setup({program, Controller, Token, _} = Program, Owner, Mode, Fifo, Marker) ->
    {ok, #{exit_status := 0, stdout := Ready}} =
        tmux_transport:run(<<"/bin/cat">>, [Fifo], #{timeout_ms => 900, max_stdout => 200}),
    [Leader, Child, Leader, Socket] = binary:split(string:trim(Ready), <<"\t">>, [global]),
    {error, #{code := await_timeout}} = tmux_program:await_started(Program, 0),
    #{ownership := {owned_server, Owned, _}, terminal_holder := none} = sys:get_state(Controller),
    #{endpoint := Endpoint, socket := Socket, phase := running} = sys:get_state(Owned),
    {ok, #{stdout := Daemon}} = tmux_target:run(Endpoint, <<"display-message">>, [<<"-p">>, <<"#{pid}">>]),
    Identities = [observe(Pid) || Pid <- [Leader, Child, string:trim(Daemon)]],
    Monitor = monitor(process, Controller),
    Collection = gen_server:send_request(Controller, {Token, await, make_ref()}),
    #{waiters := Waiters} = sys:get_state(Controller),
    1 = map_size(Waiters),
    Expected = case Mode of
        stop -> {ok, stop_requested} = tmux_program:stop(Program), program_stopped;
        owner_exit -> Owner ! finish, program_owner_exited
    end,
    {reply, {error, #{code := Expected, cleanup := complete}}} =
        gen_server:receive_response(Collection, 900),
    lists:foreach(fun({Pid, Identity}) ->
        {error, #{code := stale_server}} = tmux_identity:check(Identity, Pid)
    end, Identities),
    {error, enoent} = file:read_link_info(Socket),
    {error, enoent} = file:read_link_info(filename:dirname(Socket)),
    {error, enoent} = file:read_file(Marker),
    case Mode of
        stop -> ok = tmux_program:release(Program), Owner ! finish;
        owner_exit -> ok
    end,
    wait_exit(Monitor, Controller).

with_env(Env, Function) ->
    Previous = [{Name, os:getenv(Name)} || {Name, _} <- Env],
    lists:foreach(fun set_env/1, Env),
    try Function()
    after lists:foreach(fun set_env/1, Previous)
    end.

set_env({Name, false}) -> true = os:unsetenv(Name);
set_env({Name, Value}) -> true = os:putenv(Name, Value).

observe(Text) ->
    Pid = binary_to_integer(Text),
    {ok, Identity} = tmux_identity:observe(Pid),
    {Pid, Identity}.

wait_exit(Monitor, Pid) ->
    receive {'DOWN', Monitor, process, Pid, normal} -> ok
    after 900 -> ct:fail({retirement_timeout, Pid})
    end.

retire_program(Program) ->
    _ = tmux_program:stop(Program),
    _ = tmux_program:await(Program, 900),
    ok = tmux_program:release(Program).
