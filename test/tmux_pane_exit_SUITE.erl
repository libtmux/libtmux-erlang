-module(tmux_pane_exit_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         exit_status/1, waits_for_a_running_pane/1, killed_by_signal/1,
         waits_after_pty_closes/1, closed_pty_requires_generation/1,
         fast_eof_before_watch/1, retention_required/1, deadline/1,
         vanished_pane/1, invalid_options/1, hook_removed/1,
         caller_death_removes_hook/1, respawn_does_not_replace_exit/1,
         closed_pty_live_deadline/1, unpublished_exit_deadline/1,
         deadline_before_action/1, vanished_during_wait/1,
         replaced_running_pane/1, cancelled_wait/1,
         replacement_daemon/1, native_wait_registered_without_hooks/1,
         client_daemon_mismatch/1, client_readiness_keeps_endpoint_responsive/1,
         late_readiness_preserves_result/1, late_readiness_tolerates_eviction/1]).

%% Outer: a pane's exit status and signal exist only on an owned native server.
all() -> [exit_status, waits_for_a_running_pane, killed_by_signal,
          waits_after_pty_closes, closed_pty_requires_generation,
          fast_eof_before_watch, retention_required, deadline, vanished_pane,
          invalid_options, hook_removed, caller_death_removes_hook,
          respawn_does_not_replace_exit, closed_pty_live_deadline,
          unpublished_exit_deadline, deadline_before_action,
          vanished_during_wait, replaced_running_pane,
          cancelled_wait, replacement_daemon, native_wait_registered_without_hooks,
          client_daemon_mismatch, client_readiness_keeps_endpoint_responsive,
          late_readiness_preserves_result, late_readiness_tolerates_eviction].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

exit_status(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        {Child, Arguments} = tmux_test_child:command(<<"write">>, [<<>>, <<>>, <<"7">>]),
        lists:foreach(fun({Argv, Expected}) ->
            Pane = job(Window, Fixture, Argv, false),
            {ok, #{exit := Expected, pane := Dead}} =
                tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}),
            true = tmux_model:get(dead, Dead),
            {ok, _} = tmux_pane:kill(Dead)
        end, [{[<<"/bin/true">>], {status, 0}},
              {[<<"/bin/false">>], {status, 1}},
              {[Child | Arguments], {status, 7}}])
    end).

waits_for_a_running_pane(Config) ->
    Log = filename:join(proplists:get_value(priv_dir, Config), "tmux"),
    with_window(Config, true, #{log_directory => Log}, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        Self = self(),
        Waiter = spawn_link(fun() ->
            Start = fun() -> Self ! {watching, self()}, ok end,
            Self ! {done, tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}, Start)}
        end),
        receive {watching, Waiter} -> ok
        after 900 -> ct:fail(waiter_did_not_register_hook) end,
        {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
        Result = receive {done, Outcome} -> Outcome
            after 6000 -> report_unexpected_exit(Fixture, Pane, waiter_timeout) end,
        unlink(Waiter),
        Dead = case Result of
            {ok, #{exit := {status, 0}, pane := Completed}} -> Completed;
            _ -> report_unexpected_exit(Fixture, Pane, Result)
        end,
        %% The pane is dead now, so a second call reads the same outcome.
        {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Dead, #{}),
        {error, #{code := target_already_exited, outcome := not_started}} =
            tmux_pane:wait_exit(Dead, #{}, fun() -> error(start_callback_ran) end)
    end).

report_unexpected_exit(Fixture, Pane, Outcome) ->
    #{server_pid := Server, helper_pid := Helper, log_directory := Log} =
        tmux_test_fixture:info(Fixture),
    Id = tmux_model:get(id, Pane),
    Format = <<"#{pane_id}|#{pane_dead}|#{pane_dead_status}|#{pane_dead_signal}|#{pane_pid}">>,
    Native = tmux_test_fixture:command(Fixture,
        [<<"display-message">>, <<"-p">>, <<"-t">>, Id, <<"-F">>, Format]),
    Clients = tmux_test_fixture:command(Fixture,
        [<<"list-clients">>, <<"-F">>, <<"#{client_pid}|#{client_flags}">>]),
    ct:fail({unexpected_pane_exit,
        #{expected => {status, 0}, observed => Outcome, server_pid => Server,
          helper_pid => Helper, pane => Id, pane_pid => tmux_model:get(pid, Pane),
          current_command_at_split => tmux_model:get(current_command, Pane),
          native => Native, clients => Clients, tmux_log => Log}}).

waits_after_pty_closes(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        #{directory := Directory} = tmux_test_fixture:info(Fixture),
        Ready = list_to_binary(filename:join(Directory, "ready")),
        Release = list_to_binary(filename:join(Directory, "release")),
        {ok, #{exit_status := 0}} = tmux_transport:run(
            <<"/usr/bin/mkfifo">>, [Ready, Release], #{timeout_ms => 900}),
        Script = <<"IFS= read -r token; trap '' HUP; exec 0<&- 1>&- 2>&-; ",
                   "printf '%s\\n' \"$$\" > \"$1\"; IFS= read -r token < \"$2\"; exit 7">>,
        Pane = job(Window, Fixture, [<<"/bin/sh">>, <<"-c">>, Script, <<"exit-child">>,
                                    Ready, Release]),
        Start = fun() ->
            {ok, _} = tmux_pane:send_text(Pane, <<"close\n">>),
            {ok, #{exit_status := 0}} = tmux_transport:run(
                <<"/bin/cat">>, [Ready], #{timeout_ms => 900, max_stdout => 32}),
            {ok, #{exit_status := 0}} = release_child(Release),
            ok
        end,
        {ok, #{exit := {status, 7}}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}, Start)
    end).

closed_pty_requires_generation(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        #{directory := Directory} = tmux_test_fixture:info(Fixture),
        Ready = list_to_binary(filename:join(Directory, "ready")),
        Release = list_to_binary(filename:join(Directory, "release")),
        {ok, #{exit_status := 0}} = tmux_transport:run(
            <<"/usr/bin/mkfifo">>, [Ready, Release], #{timeout_ms => 900}),
        % Keep the child alive after it closes the terminal descriptors.
        Script = <<"trap '' HUP; exec 0<&- 1>&- 2>&-; ",
                   "printf '%s\\n' \"$$\" > \"$1\"; IFS= read -r token < \"$2\"; exit 7">>,
        Pane = job(Window, Fixture, [<<"/bin/sh">>, <<"-c">>, Script, <<"exit-child">>,
                                    Ready, Release], false),
        {ok, #{exit_status := 0, stdout := PidLine}} = tmux_transport:run(
            <<"/bin/cat">>, [Ready], #{timeout_ms => 900, max_stdout => 32}),
        Pid = binary_to_integer(string:trim(PidLine)),
        Identity = tmux_test_fixture:process_identity(Pid),
        ok = tmux_test_fixture:track_process(Fixture, Pid),
        Id = tmux_model:get(id, Pane),
        ok = wait_for_pty_close(Fixture, Id, 32),
        true = tmux_test_fixture:same_process(Pid, Identity),
        {error, #{code := pane_generation_unavailable}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 100}),
        {ok, _} = tmux_option:set(Pane, <<"remain-on-exit">>, <<"failed">>),
        {ok, #{exit_status := 0, stdout := Dead}} = tmux_test_fixture:command(
            Fixture, [<<"display-message">>, <<"-p">>, <<"-t">>, Id, <<"-F">>, <<"#{pane_dead}">>]),
        Refusal = case Dead of
            <<"1\n">> -> pane_generation_unavailable;
            <<"0\n">> -> remain_on_exit_required
        end,
        {error, #{code := Refusal}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 100}),
        {ok, _} = tmux_option:set(Pane, <<"remain-on-exit">>, <<"on">>),
        {ok, Signal} = tmux_command:wait_for(<<"closed-pty-exit">>, signal),
        {ok, _} = tmux_hook:set(Pane, {<<"pane-died">>, 31}, Signal),
        {ok, Wait} = tmux_test_fixture:start_command(Fixture,
            [<<"wait-for">>, <<"closed-pty-exit">>]),
        try
            {ok, #{exit_status := 0}} = release_child(Release),
            {ok, #{exit_status := 0}} = tmux_transport:await(Wait, 900)
        after _ = tmux_transport:close(Wait)
        end,
        {ok, #{exit := {status, 7}}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 5000})
    end).

release_child(Release) ->
    tmux_transport:run(<<"/bin/sh">>,
        [<<"-c">>, <<"printf 'done\\n' > \"$1\"">>, <<"exit-release">>, Release],
        #{timeout_ms => 900}).

closed_pty_live_deadline(Config) ->
    with_reap_fixture(Config, fun(_Probe, Gate, Daemon, Window, Fixture) ->
        {Pane, Ready, Release} = gated_child(Window, Fixture),
        Pid = tmux_model:get(pid, Pane),
        {ok, Identity} = tmux_identity:observe(Pid),
        Children = supervised_pids(),
        Before = existing_exit_hook(Pane),
        Start = fun() ->
            put(exit_resources, capture_exit_resources(Fixture, Children)),
            gate_child_pty(Gate, Daemon, Pane, Ready, Fixture),
            ok = tmux_identity:check(Identity, Pid),
            ok
        end,
        try
            Result = tmux_pane:wait_exit(Pane, #{deadline_ms => 300}, Start),
            native_unpublished(Fixture, Pane),
            assert_exit_resources(erase(exit_resources)),
            Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
            {error, #{code := deadline}} = Result
        after restore_reaping(Gate, Daemon)
        end,
        ok = tmux_identity:check(Identity, Pid),
        published_child_exit(Fixture, Pane, fun() -> release_child(Release) end)
    end).

unpublished_exit_deadline(Config) ->
    with_reap_fixture(Config, fun(Probe, Gate, Daemon, Window, Fixture) ->
        {Pane, Ready, Release} = gated_child(Window, Fixture),
        Pid = tmux_model:get(pid, Pane),
        {ok, Identity} = tmux_identity:observe(Pid),
        Children = supervised_pids(),
        Before = existing_exit_hook(Pane),
        Start = fun() ->
            put(exit_resources, capture_exit_resources(Fixture, Children)),
            gate_child_pty(Gate, Daemon, Pane, Ready, Fixture),
            ok = tmux_identity:check(Identity, Pid),
            {ok, #{exit_status := 0}} = release_child(Release),
            {ok, #{exit_status := 0, stdout := <<"exited\n">>}} =
                tmux_transport:run(Probe, [integer_to_binary(Pid)], #{timeout_ms => 900}),
            {error, #{code := target_gone}} = tmux_identity:observe(Pid),
            native_unpublished(Fixture, Pane),
            ok
        end,
        try
            Result = tmux_pane:wait_exit(Pane, #{deadline_ms => 300}, Start),
            native_unpublished(Fixture, Pane),
            assert_exit_resources(erase(exit_resources)),
            Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
            {error, #{code := exit_status_unavailable, cleanup := complete,
                      reason := native_outcome_unpublished, daemon_version := _,
                      hint := <<_, _/binary>>}} = Result
        after
            published_child_exit(Fixture, Pane, fun() -> restore_reaping(Gate, Daemon) end)
        end
    end).

with_reap_fixture(Config, Function) ->
    {Probe, Preload} = compile_reap_fixture(Config),
    {ok, Directory} = tmux_test_sandbox:fixture_directory(),
    Gate = filename:join(Directory, "reap-gate"),
    Previous = [{Name, os:getenv(Name)} || Name <-
        ["LD_PRELOAD", "LIBTMUX_TEST_REAP_GATE"]],
    true = os:putenv("LD_PRELOAD", binary_to_list(Preload)),
    true = os:putenv("LIBTMUX_TEST_REAP_GATE", Gate),
    try with_window(Config, true, fun(_Server, Window, Fixture) ->
        #{server_pid := Daemon} = tmux_test_fixture:info(Fixture),
        Function(Probe, Gate, Daemon, Window, Fixture)
    end)
    after
        lists:foreach(fun
            ({Name, false}) -> true = os:unsetenv(Name);
            ({Name, Value}) -> true = os:putenv(Name, Value)
        end, Previous)
    end.

existing_exit_hook(Pane) ->
    {ok, Existing} = tmux_command:raw(<<"display-message">>, [<<"existing-hook">>]),
    {ok, _} = tmux_hook:set(Pane, {<<"pane-died">>, 42}, Existing),
    tmux_hook:get(Pane, <<"pane-died">>, #{}).

restore_reaping(Gate, Daemon) ->
    case file:delete(Gate) of ok -> ok; {error, enoent} -> ok end,
    {ok, #{exit_status := 0}} = tmux_transport:run(<<"/bin/kill">>,
        [<<"-CHLD">>, integer_to_binary(Daemon)], #{timeout_ms => 900}).

published_child_exit(Fixture, Pane, Release) ->
    {ok, Signal} = tmux_command:wait_for(<<"gated-child-exit">>, signal),
    {ok, _} = tmux_hook:set(Pane, {<<"pane-died">>, 31}, Signal),
    {ok, Published} = tmux_test_fixture:start_command(Fixture,
        [<<"wait-for">>, <<"gated-child-exit">>]),
    try
        {ok, #{exit_status := 0}} = Release(),
        {ok, #{exit_status := 0}} = tmux_transport:await(Published, 900),
        {ok, #{exit := {status, 7}}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 900})
    after
        _ = tmux_transport:close(Published),
        {ok, _} = tmux_hook:unset(Pane, {<<"pane-died">>, 31})
    end.

compile_reap_fixture(Config) ->
    {ok, Directory} = tmux_test_sandbox:fixture_directory(),
    Probe = list_to_binary(filename:join(Directory, "reap-probe")),
    Preload = list_to_binary(filename:join(Directory, "reap-gate.so")),
    Source = list_to_binary(filename:join(proplists:get_value(data_dir, Config), "reap_gate.c")),
    Compiler = list_to_binary(os:find_executable("cc")),
    Flags = [<<"-std=c11">>, <<"-Wall">>, <<"-Wextra">>, <<"-Werror">>],
    lists:foreach(fun({Output, Extra}) ->
        {ok, #{exit_status := 0}} = tmux_transport:run(Compiler,
            Flags ++ Extra ++ [Source, <<"-o">>, Output, <<"-ldl">>], #{timeout_ms => 900})
    end, [{Probe, []}, {Preload, [<<"-shared">>, <<"-fPIC">>]}]),
    {Probe, Preload}.

gated_child(Window, Fixture) ->
    #{directory := Directory} = tmux_test_fixture:info(Fixture),
    Ready = list_to_binary(filename:join(Directory, "ready")),
    Release = list_to_binary(filename:join(Directory, "release")),
    {ok, #{exit_status := 0}} = tmux_transport:run(
        <<"/usr/bin/mkfifo">>, [Ready, Release], #{timeout_ms => 900}),
    Script = <<"trap '' HUP; IFS= read -r token; exec 0<&- 1>&- 2>&-; ",
               "printf '%s\\n' \"$$\" > \"$1\"; IFS= read -r token < \"$2\"; exit 7">>,
    Pane = job(Window, Fixture, [<<"/bin/sh">>, <<"-c">>, Script, <<"exit-child">>, Ready, Release]),
    {Pane, Ready, Release}.

gate_child_pty(Gate, Daemon, Pane, Ready, Fixture) ->
    {ok, #{exit_status := 0, stdout := TtyLine}} = tmux_test_fixture:command(Fixture,
        [<<"display-message">>, <<"-p">>, <<"-t">>, tmux_model:get(id, Pane), <<"#{pane_tty}">>]),
    Tty = string:trim(TtyLine),
    ok = file:write_file(Gate, [integer_to_binary(Daemon), " ", filename:basename(Tty)]),
    {ok, _} = tmux_pane:send_text(Pane, <<"close\n">>),
    {ok, #{exit_status := 0}} = tmux_transport:run(
        <<"/bin/cat">>, [Ready], #{timeout_ms => 900, max_stdout => 32}),
    wait_for_pty_close(Fixture, tmux_model:get(id, Pane), 32).

capture_exit_resources(Fixture, Children) ->
    Resources = [{Child, monitor(process, Child)} || Child <- supervised_pids() -- Children],
    #{holder := Holder, operation := {operation, Endpoint, _, Lease}} = sys:get_state(exit_wait_owner()),
    #{operations := Operations} = sys:get_state(Endpoint),
    #{handle := Wait} = maps:get(Lease, Operations),
    Handles = [Holder, Wait],
    OsPids = lists:flatmap(fun(Handle) ->
        {ok, _} = tmux_transport:await_started(Handle, 900),
        {ok, #{helper_pid := Helper, child_pid := Child}} = tmux_transport:status(Handle),
        [Helper, Child]
    end, Handles),
    Processes = [begin
        ok = tmux_test_fixture:track_process(Fixture, Child),
        {Child, tmux_test_fixture:process_identity(Child)}
    end || Child <- lists:usort(OsPids)],
    {Resources, Processes}.

exit_wait_owner() ->
    [Owner] = [Child || {_, Child, _, [tmux_pane_exit_owner]} <-
        supervisor:which_children(tmux_sup), is_pid(Child)],
    Owner.

assert_exit_resources({Resources, Processes}) ->
    lists:foreach(fun({Child, Ref}) -> wait_down(Child, Ref) end, Resources),
    lists:foreach(fun({Child, Birth}) ->
        false = tmux_test_fixture:same_process(Child, Birth)
    end, Processes).

native_unpublished(Fixture, Pane) ->
    Format = <<"#{pane_dead}\t#{pane_dead_status}\t#{pane_dead_signal}\t#{pane_pid}\t#{pane_tty}">>,
    {ok, #{exit_status := 0, stdout := Output}} = tmux_test_fixture:command(Fixture,
        [<<"display-message">>, <<"-p">>, <<"-t">>, tmux_model:get(id, Pane), <<"-F">>, Format]),
    [Dead, <<>>, <<>>, Pid, Tty] = binary:split(string:trim(Output, trailing, "\n"), <<"\t">>, [global]),
    true = Dead =:= <<"1">> orelse Pid =:= <<>>,
    ct:pal("unpublished native outcome: ~p", [#{dead => Dead, pid => Pid, tty => Tty}]),
    ok.

fast_eof_before_watch(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        {ok, Signal} = tmux_command:wait_for(<<"fast-eof-exit">>, signal),
        {ok, _} = tmux_hook:set(Pane, {<<"pane-died">>, 31}, Signal),
        {ok, Published} = tmux_test_fixture:start_command(Fixture,
            [<<"wait-for">>, <<"fast-eof-exit">>]),
        Parent = self(),
        {Waiter, Monitor} = spawn_monitor(fun() ->
            Parent ! {self(), tmux_pane:wait_exit(Pane, #{deadline_ms => 5000})}
        end),
        try
            {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
            Result = receive {Waiter, Result0} -> Result0
                after 900 -> ct:fail(fast_eof_waiter_timeout) end,
            case Result of
                {ok, #{exit := {status, 0}}} -> ct:pal("fast EOF: observed exit 0");
                {error, #{code := pane_generation_unavailable}} ->
                    ct:pal("fast EOF: generation unavailable");
                _ -> ct:fail({unexpected_fast_eof_receipt, Result})
            end,
            wait_down(Waiter, Monitor),
            {ok, #{exit_status := 0}} = tmux_transport:await(Published, 900),
            {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Pane, #{})
        after
            exit(Waiter, kill),
            demonitor(Monitor, [flush]),
            _ = tmux_transport:close(Published)
        end
    end).

wait_for_pty_close(Fixture, Id, Remaining) when Remaining > 0 ->
    % A fresh pane has no pipe. With no command, tmux only checks the pane.
    case tmux_test_fixture:command(Fixture, [<<"pipe-pane">>, <<"-t">>, Id]) of
        {ok, #{exit_status := 1, stderr := <<"target pane has exited\n">>}} -> ok;
        {ok, #{exit_status := 0}} -> wait_for_pty_close(Fixture, Id, Remaining - 1);
        Other -> ct:fail({pty_close_probe_failed, Other})
    end;
wait_for_pty_close(_, _, 0) -> ct:fail(pty_still_open).

killed_by_signal(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        lists:foreach(fun({Name, Number}) ->
            Pane = job(Window, Fixture, [<<"/bin/sleep">>, <<"600">>]),
            Pid = integer_to_binary(tmux_model:get(pid, Pane)),
            {ok, #{exit_status := 0}} = tmux_transport:run(<<"/bin/kill">>,
                [<<"-", Name/binary>>, Pid], #{}),
            {ok, #{exit := {signal, Number}, pane := Dead}} =
                tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}),
            %% tmux publishes a signal death without an exit status.
            none = tmux_model:get(exit_status, Dead),
            {ok, _} = tmux_pane:kill(Dead)
        end, [{<<"HUP">>, 1}, {<<"TERM">>, 15}, {<<"KILL">>, 9}])
    end).

retention_required(Config) ->
    with_window(Config, false, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, [<<"/bin/cat">>]),
        {error, #{code := remain_on_exit_required}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 500}),
        {ok, _} = tmux_option:set(Pane, <<"remain-on-exit">>, <<"failed">>),
        {error, #{code := remain_on_exit_required}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 500})
    end).

deadline(Config) ->
    with_window(Config, true, fun(Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        Children = supervised_pids(),
        BeforeHook = existing_exit_hook(Pane),
        BeforeWaiters = event_waiters(Server, Fixture),
        Start = fun() -> put(exit_resources, capture_exit_resources(Fixture, Children)), ok end,
        {error, #{code := deadline}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 300}, Start),
        assert_exit_resources(erase(exit_resources)),
        BeforeHook = tmux_hook:get(Pane, <<"pane-died">>, #{}),
        BeforeWaiters = event_waiters(Server, Fixture),
        %% A timed-out wait leaves the live pane usable for another wait.
        {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
        {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 5000})
    end).


deadline_before_action(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Original = job(Window, Fixture, eof_reader()),
        #{directory := Directory, executable := Executable, socket := Socket} =
            tmux_test_fixture:info(Fixture),
        Wrapper = list_to_binary(filename:join(Directory, "gate-client")),
        Entered = list_to_binary(filename:join(Directory, "gate-entered")),
        Release = list_to_binary(filename:join(Directory, "gate-release")),
        ok = file:make_symlink(Executable, filename:join(Directory, "tmux")),
        ok = file:write_file(Wrapper, post_arm_gate()),
        ok = file:change_mode(Wrapper, 8#700),
        {ok, #{exit_status := 0}} = tmux_transport:run(
            <<"/usr/bin/mkfifo">>, [Entered, Release], #{timeout_ms => 900}),
        {ok, Endpoint} = tmux_server:open(#{socket_path => Socket, executable => Wrapper}),
        try
            {ok, Pane} = tmux_pane:get(Endpoint, tmux_model:get(id, Original)),
            expire_during_recheck(Pane, Entered, Release)
        after ok = tmux_server:close(Endpoint)
        end
    end).

%% Pause only the second exit-state read, after the native wait is armed.
post_arm_gate() ->
    <<"#!/bin/sh\n"
      "set -eu\n"
      "dir=$(dirname \"$0\")\n"
      "case \"$*\" in\n"
      "  *'#{remain-on-exit}'*'#{pane_dead_status}'*)\n"
      "    if [ ! -e \"$dir/seen\" ]; then\n"
      "      : > \"$dir/seen\"\n"
      "    elif [ ! -e \"$dir/blocked\" ]; then\n"
      "      : > \"$dir/blocked\"\n"
      "      printf 'ready\\n' > \"$dir/gate-entered\"\n"
      "      IFS= read -r release < \"$dir/gate-release\"\n"
      "    fi;;\n"
      "esac\n"
      "exec \"$dir/tmux\" \"$@\"\n">>.

expire_during_recheck(Pane, Entered, Release) ->
    Parent = self(),
    {Waiter, Monitor} = spawn_monitor(fun() ->
        Start = fun() -> Parent ! {self(), action_started}, ok end,
        Parent ! {self(), tmux_pane:wait_exit(Pane, #{deadline_ms => 400}, Start)}
    end),
    try
        {ok, #{exit_status := 0, stdout := <<"ready\n">>}} = tmux_transport:run(
            <<"/bin/cat">>, [Entered], #{timeout_ms => 900, max_stdout => 16}),
        #{operation := Operation} = sys:get_state(exit_wait_owner()),
        {error, #{code := deadline, cleanup := complete}} =
            tmux_operation:await(Operation, 900),
        {ok, #{exit_status := 0}} = release_child(Release),
        receive
            {Waiter, action_started} -> ct:fail(expired_wait_started_action);
            {Waiter, {error, #{code := deadline, cleanup := complete}}} -> ok
        after 900 -> ct:fail(expired_wait_did_not_return)
        end,
        wait_down(Waiter, Monitor)
    after
        exit(Waiter, kill),
        demonitor(Monitor, [flush])
    end.

vanished_during_wait(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        Children = supervised_pids(),
        Start = fun() ->
            put(exit_resources, capture_exit_resources(Fixture, Children)),
            {ok, _} = tmux_pane:kill(Pane),
            ok
        end,
        {error, #{code := target_gone}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 100}, Start),
        assert_exit_resources(erase(exit_resources))
    end).

replaced_running_pane(Config) ->
    with_window(Config, true, fun(Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        Children = supervised_pids(),
        Start = fun() ->
            put(exit_resources, capture_exit_resources(Fixture, Children)),
            {ok, _} = tmux_pane:respawn(Pane,
                #{force => true, launch => #{argv => eof_reader()}}),
            {ok, Current} = tmux_pane:get(Server, tmux_model:get(id, Pane)),
            ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Current)),
            ok
        end,
        {error, #{code := stale_pane}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 100}, Start),
        assert_exit_resources(erase(exit_resources))
    end).

cancelled_wait(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        Children = supervised_pids(),
        Before = existing_exit_hook(Pane),
        Start = fun() ->
            put(exit_resources, capture_exit_resources(Fixture, Children)),
            #{operation := Operation} = sys:get_state(exit_wait_owner()),
            {ok, cancel_requested} = tmux_operation:cancel(Operation),
            ok
        end,
        {error, #{code := cancelled}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 900}, Start),
        assert_exit_resources(erase(exit_resources)),
        Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
        {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
        {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 900})
    end).

replacement_daemon(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        {Waiter, Monitor} = paused_waiter(Pane),
        try
            ok = tmux_test_fixture:replace(Fixture),
            #{socket := Socket, executable := Executable} = tmux_test_fixture:info(Fixture),
            {ok, Replacement} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
            try
                {ok, _} = tmux_session:create(Replacement,
                    #{name => <<"replacement">>, launch => #{argv => [<<"/bin/cat">>]}}),
                {ok, Snapshot} = tmux_server:snapshot(Replacement),
                [NextWindow] = tmux_snapshot:windows(Snapshot),
                {ok, _} = tmux_option:set(NextWindow, <<"remain-on-exit">>, <<"on">>),
                NextPane = job(NextWindow, Fixture,
                    [<<"/bin/sh">>, <<"-c">>, <<"exit 23">>], false),
                Id = tmux_model:get(id, Pane),
                Id = tmux_model:get(id, NextPane),
                {ok, #{exit := {status, 23}}} = tmux_pane:wait_exit(NextPane, #{}),
                Waiter ! resume,
                Result = receive {Waiter, Reply} -> Reply
                    after 900 -> ct:fail(old_daemon_waiter_did_not_finish) end,
                wait_down(Waiter, Monitor),
                case Result of
                    {error, #{code := stale_server}} -> ok;
                    _ -> ct:fail({replacement_daemon_wait_result, Result})
                end,
                {ok, _} = tmux_server:snapshot(Replacement)
            after ok = tmux_server:close(Replacement)
            end
        after
            exit(Waiter, kill),
            demonitor(Monitor, [flush])
        end
    end).

vanished_pane(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, [<<"/bin/cat">>]),
        {ok, _} = tmux_pane:kill(Pane),
        {error, #{code := target_gone}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 500})
    end).

invalid_options(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, [<<"/bin/cat">>]),
        {error, #{code := invalid_option, path := [deadline_ms]}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 0}),
        {error, #{code := unknown_option, path := [timeout]}} =
            tmux_pane:wait_exit(Pane, #{timeout => 1}),
        {error, #{code := invalid_options}} = tmux_pane:wait_exit(Pane, []),
        {error, #{code := detached_reference}} = tmux_pane:wait_exit(
            element(2, tmux_model:pane(#{id => <<"%1">>})), #{})
    end).

hook_removed(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        Children = supervised_pids(),
        Start = fun() ->
            put(exit_resources, capture_exit_resources(Fixture, Children)),
            {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
            ok
        end,
        {ok, #{exit := {status, 0}}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}, Start),
        assert_exit_resources(erase(exit_resources)),
        case tmux_hook:get(Pane, <<"pane-died">>, #{}) of
            none -> ok;
            {ok, Entries} -> 0 = map_size(Entries)
        end
    end).

native_wait_registered_without_hooks(Config) ->
    with_window(Config, true, fun(Server, Window, Fixture) ->
        {ok, Version} = tmux_server:version(Server),
        case tmux_version:at_least(Version, <<"3.8">>) of
            false -> {skip, native_events_require_tmux_3_8};
            true ->
                Pane = job(Window, Fixture, eof_reader()),
                Other = job(Window, Fixture, eof_reader()),
                {ok, Existing} = tmux_command:raw(<<"display-message">>, [<<"existing-hook">>]),
                {ok, _} = tmux_hook:set(Pane, {<<"pane-died">>, 42}, Existing),
                Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
                Start = fun() ->
                    Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
                    {ok, #{exit_status := 0, stdout := Waiters}} =
                        tmux_test_fixture:command(Fixture,
                            [<<"wait-for">>, <<"-E">>, <<"-l">>, <<"pane-died">>]),
                    [_] = [Line || Line <- binary:split(Waiters, <<"\n">>, [global]),
                                   Line =/= <<>>],
                    {ok, _} = tmux_pane:send_keys(Other, [{control, <<"d">>}]),
                    {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Other, #{}),
                    {ok, #{exit_status := 0, stdout := Waiters}} =
                        tmux_test_fixture:command(Fixture,
                            [<<"wait-for">>, <<"-E">>, <<"-l">>, <<"pane-died">>]),
                    {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
                    ok
                end,
                {ok, #{exit := {status, 0}}} =
                    tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}, Start),
                Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
                {ok, #{exit_status := 0, stdout := <<>>}} =
                    tmux_test_fixture:command(Fixture,
                        [<<"wait-for">>, <<"-E">>, <<"-l">>, <<"pane-died">>])
        end
    end).

client_daemon_mismatch(Config) ->
    case os:getenv("LIBTMUX_TEST_PEER_TMUX") of
        false -> {skip, peer_tmux_not_selected};
        PeerPath ->
            Peer = list_to_binary(PeerPath),
            with_window(Config, true, fun(Server, Window, Fixture) ->
                {ok, DaemonVersion} = tmux_server:version(Server),
                DaemonRelease = tmux_version:format(DaemonVersion),
                {ok, #{exit_status := 0, stdout := Raw}} =
                    tmux_transport:run(Peer, [<<"-V">>], #{max_stdout => 64}),
                {ok, ClientVersion} = tmux_version:parse(string:trim(Raw)),
                true = tmux_version:format(ClientVersion) =/= DaemonRelease,
                #{socket := Socket} = tmux_test_fixture:info(Fixture),
                case tmux_server:open(#{socket_path => Socket, executable => Peer}) of
                    {error, #{code := command_error, exit_status := 1,
                              cleanup := complete, stderr := Refusal}} ->
                        {ok, #{exit_status := 0, stdout := Current}} =
                            tmux_test_fixture:command(Fixture,
                                [<<"display-message">>, <<"-p">>, <<"#{version}">>]),
                        {ok, CurrentVersion} = tmux_version:parse(
                            <<"tmux ", (string:trim(Current))/binary>>),
                        DaemonRelease = tmux_version:format(CurrentVersion),
                        ct:pal("native client/daemon mismatch refused: ~p", [Refusal]);
                    {ok, Endpoint} ->
                        try
                            {ok, DaemonVersion} = tmux_server:version(Endpoint),
                            {ok, OtherWindow} = tmux_window:get(Endpoint,
                                tmux_model:get(id, Window)),
                            Pane = job(OtherWindow, Fixture, eof_reader()),
                            Before = hook_entries(Pane),
                            Start = fun() ->
                                case event_waiters(Endpoint, Fixture) of
                                    legacy -> 1 = map_size(hook_entries(Pane));
                                    Waiters ->
                                        true = byte_size(Waiters) > 0,
                                        Before = hook_entries(Pane)
                                end,
                                {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
                                ok
                            end,
                            {ok, #{exit := {status, 0}}} =
                                tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}, Start),
                            Before = hook_entries(Pane)
                        after ok = tmux_server:close(Endpoint)
                        end
                end
            end)
    end.

client_readiness_keeps_endpoint_responsive(Config) ->
    with_window(Config, true, fun(Server, _Window, _Fixture) ->
        {ok, Wait} = tmux_command:wait_for(<<"client-readiness">>, wait),
        {ok, Operation = {operation, Endpoint, Generation, Lease}} =
            tmux_operation:start(Server, Wait, #{deadline_ms => 5000}),
        {ok, #{phase := sent}} = tmux_operation:await_started(Operation, 900),
        #{operations := Operations} = sys:get_state(Endpoint),
        #{handle := {transport, Transport, _}} = maps:get(Lease, Operations),
        ok = sys:suspend(Transport),
        try
            Client = gen_server:send_request(Endpoint,
                {Generation, operation, Lease, client_pid, make_ref()}),
            Version = gen_server:send_request(Endpoint, {Generation, version, make_ref()}),
            {reply, {ok, _}} = gen_server:receive_response(Version, 100),
            ok = sys:resume(Transport),
            {reply, {ok, Pid}} = gen_server:receive_response(Client, 900),
            true = is_integer(Pid)
        after
            _ = sys:resume(Transport),
            _ = tmux_operation:cancel(Operation),
            {error, #{code := cancelled, cleanup := complete}} =
                tmux_operation:await(Operation, 900)
        end
    end).

late_readiness_preserves_result(Config) ->
    with_window(Config, true, fun(Server, _Window, Fixture) ->
        {Operation = {operation, Endpoint, _, Lease}, Handle, Receipt} =
            completed_wait(Server, Fixture),
        Reply = make_ref(),
        ok = late_readiness(Endpoint, Lease, Handle, {self(), Reply}),
        receive {Reply, {error, #{code := operation_client_unavailable}}} -> ok
        after 900 -> ct:fail(late_readiness_reply_missing)
        end,
        Receipt = tmux_operation:await(Operation, 900)
    end).

late_readiness_tolerates_eviction(Config) ->
    with_window(Config, true, fun(Server, _Window, Fixture) ->
        {Operation = {operation, Endpoint, _, Lease}, Handle, _} =
            completed_wait(Server, Fixture),
        #{sweep := Timer} = sys:replace_state(Endpoint, fun(State) ->
            Past = erlang:monotonic_time(millisecond) - 1,
            Completed = queue:from_list([{Id, Past} ||
                {Id, _} <- queue:to_list(maps:get(completed, State))]),
            State#{completed => Completed}
        end),
        Endpoint ! {timeout, Timer, sweep},
        {error, #{code := operation_expired}} = tmux_operation:status(Operation),
        ok = late_readiness(Endpoint, Lease, Handle, none),
        {ok, _} = tmux_server:version(Server),
        #{requests := Requests} = sys:get_state(Endpoint),
        0 = gen_server:reqids_size(Requests)
    end).

completed_wait(Server, Fixture) ->
    {ok, Wait} = tmux_command:wait_for(<<"late-readiness">>, wait),
    {ok, Operation = {operation, Endpoint, _, Lease}} =
        tmux_operation:start(Server, Wait, #{deadline_ms => 5000}),
    {ok, #{phase := sent}} = tmux_operation:await_started(Operation, 900),
    #{operations := Operations} = sys:get_state(Endpoint),
    #{handle := Handle = {transport, Worker, _}} = maps:get(Lease, Operations),
    Monitor = monitor(process, Worker),
    {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"wait-for">>, <<"-S">>, <<"late-readiness">>]),
    {ok, #{cleanup := complete}} = Receipt = tmux_operation:await(Operation, 900),
    wait_down(Worker, Monitor),
    {Operation, Handle, Receipt}.

late_readiness(Endpoint, Lease, Handle, Waiter) ->
    _ = sys:replace_state(Endpoint, fun(State) ->
        Tag = make_ref(),
        Request = tmux_transport:send_request(Handle, started),
        Requests = gen_server:reqids_add(Request, {Lease, command, {client_pid, Tag}},
            maps:get(requests, State)),
        case Waiter of
            none -> State#{requests => Requests};
            {Pid, _} ->
                Operations = maps:get(operations, State),
                Op = maps:get(Lease, Operations),
                Op1 = Op#{waiters => #{Tag => {client_pid, Waiter, monitor(process, Pid)}}},
                State#{operations => Operations#{Lease => Op1}, requests => Requests}
        end
    end),
    ok.

caller_death_removes_hook(Config) ->
    with_window(Config, true, fun(Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        {ok, Existing} = tmux_command:raw(<<"display-message">>, [<<"existing-hook">>]),
        {ok, _} = tmux_hook:set(Pane, {<<"pane-died">>, 42}, Existing),
        Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
        BeforeWaiters = event_waiters(Server, Fixture),
        Children = supervised_pids(),
        {Waiter, Monitor} = paused_waiter(Pane),
        Resources = capture_exit_resources(Fixture, Children),
        exit(Waiter, kill),
        wait_down(Waiter, Monitor),
        assert_exit_resources(Resources),
        BeforeWaiters = event_waiters(Server, Fixture),
        After = tmux_hook:get(Pane, <<"pane-died">>, #{}),
        case After of
            Before -> ok;
            _ -> ct:fail({caller_death_leaked_hook, #{before => Before, after_death => After}})
        end
    end).

event_waiters(Server, Fixture) ->
    {ok, Version} = tmux_server:version(Server),
    case tmux_version:at_least(Version, <<"3.8">>) of
        false -> legacy;
        true ->
            {ok, #{exit_status := 0, stdout := Waiters}} =
                tmux_test_fixture:command(Fixture,
                    [<<"wait-for">>, <<"-E">>, <<"-l">>, <<"pane-died">>]),
            Waiters
    end.

hook_entries(Pane) ->
    case tmux_hook:get(Pane, <<"pane-died">>, #{}) of
        none -> #{};
        {ok, Entries} -> Entries
    end.

respawn_does_not_replace_exit(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        lists:foreach(fun(Force) ->
            Pane = job(Window, Fixture, eof_reader()),
            {Waiter, Monitor} = paused_waiter(Pane),
            try
                case Force of
                    true -> ok;
                    false ->
                        {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
                        {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Pane, #{})
                end,
                {ok, _} = tmux_pane:respawn(Pane, #{force => Force,
                    launch => #{argv => [<<"/bin/sh">>, <<"-c">>, <<"exit 23">>]}}),
                {ok, #{exit := {status, 23}, pane := Replacement}} =
                    tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}),
                true = tmux_model:get(pid, Pane) =/= tmux_model:get(pid, Replacement),
                Waiter ! resume,
                Result = receive {Waiter, Result0} -> Result0
                    after 900 -> ct:fail(old_waiter_did_not_finish) end,
                wait_down(Waiter, Monitor),
                case Result of
                    {error, #{code := stale_pane}} -> ok;
                    _ -> ct:fail({replacement_exit_observed, Result})
                end
            after
                exit(Waiter, kill),
                demonitor(Monitor, [flush])
            end
        end, [false, true])
    end).

paused_waiter(Pane) ->
    Parent = self(),
    {Waiter, Monitor} = spawn_monitor(fun() ->
        Start = fun() ->
            Parent ! {watching, self()},
            receive resume -> ok end
        end,
        Result = tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}, Start),
        Parent ! {self(), Result}
    end),
    receive {watching, Waiter} -> {Waiter, Monitor}
    after 900 -> ct:fail(waiter_did_not_register_hook)
    end.

supervised_pids() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(tmux_sup), is_pid(Pid)].

wait_down(Pid, Monitor) ->
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 900 -> ct:fail({wait_resource_survived, Pid})
    end.

%% cat can close its standard streams before process exit. Keep the slave PTY open.
eof_reader() -> [<<"/bin/sh">>, <<"-c">>, <<"exec 3>&1; exec /bin/cat">>].

%% Jobs that end by themselves may be gone before the fixture can read them.
job(Window, Fixture, [<<"/bin/true">>] = Argv) -> job(Window, Fixture, Argv, false);
job(Window, Fixture, [<<"/bin/false">>] = Argv) -> job(Window, Fixture, Argv, false);
job(Window, Fixture, Argv) -> job(Window, Fixture, Argv, true).

job(Window, Fixture, Argv, Track) ->
    {ok, Pane} = tmux_pane:split(Window, #{launch => #{argv => Argv}}),
    case {Track, tmux_model:get(pid, Pane)} of
        {true, Pid} when is_integer(Pid) -> ok = tmux_test_fixture:track_process(Fixture, Pid);
        _ -> ok
    end,
    Pane.

with_window(Config, Retain, Fun) ->
    with_window(Config, Retain, #{}, Fun).

with_window(Config, Retain, Options, Fun) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), Options,
        fun(Server, Fixture) ->
            {ok, Session} = tmux_session:create(Server,
                #{name => <<"exit">>, launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            [Window] = tmux_snapshot:windows(Snapshot),
            [Pane] = tmux_snapshot:panes(Snapshot),
            ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane)),
            {ok, _} = tmux_option:set(Window, <<"remain-on-exit-format">>, <<>>),
            case Retain of
                true -> {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>);
                false -> ok
            end,
            _ = Session,
            Fun(Server, Window, Fixture)
        end).
