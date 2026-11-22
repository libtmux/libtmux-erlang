-module(tmux_pane_exit_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         exit_status/1, waits_for_a_running_pane/1, killed_by_signal/1,
         waits_after_pty_closes/1, closed_pty_requires_generation/1,
         fast_eof_before_watch/1, retention_required/1, deadline/1,
         vanished_pane/1, invalid_options/1, hook_removed/1,
         caller_death_removes_hook/1, respawn_does_not_replace_exit/1]).

%% Outer: a pane's exit status and signal exist only on an owned native server.
all() -> [exit_status, waits_for_a_running_pane, killed_by_signal,
          waits_after_pty_closes, closed_pty_requires_generation,
          fast_eof_before_watch, retention_required, deadline, vanished_pane,
          invalid_options, hook_removed, caller_death_removes_hook,
          respawn_does_not_replace_exit].

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
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        {error, #{code := deadline}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 100}),
        %% A timed-out wait leaves the live pane usable for another wait.
        {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
        {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 5000})
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
        Start = fun() ->
            {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
            ok
        end,
        {ok, #{exit := {status, 0}}} =
            tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}, Start),
        case tmux_hook:get(Pane, <<"pane-died">>, #{}) of
            none -> ok;
            {ok, Entries} -> 0 = map_size(Entries)
        end
    end).

caller_death_removes_hook(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, eof_reader()),
        {ok, Existing} = tmux_command:raw(<<"display-message">>, [<<"existing-hook">>]),
        {ok, _} = tmux_hook:set(Pane, {<<"pane-died">>, 42}, Existing),
        Before = tmux_hook:get(Pane, <<"pane-died">>, #{}),
        Children = supervised_pids(),
        {Waiter, Monitor} = paused_waiter(Pane),
        Resources = [{Pid, monitor(process, Pid)} || Pid <- supervised_pids() -- Children],
        Helpers = track_helpers(Fixture, Resources),
        exit(Waiter, kill),
        wait_down(Waiter, Monitor),
        lists:foreach(fun({Pid, Ref}) -> wait_down(Pid, Ref) end, Resources),
        lists:foreach(fun({Pid, Identity}) ->
            false = tmux_test_fixture:same_process(Pid, Identity)
        end, Helpers),
        After = tmux_hook:get(Pane, <<"pane-died">>, #{}),
        case After of
            Before -> ok;
            _ -> ct:fail({caller_death_leaked_hook, #{before => Before, after_death => After}})
        end
    end).

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

track_helpers(Fixture, Resources) ->
    Pids = lists:flatmap(fun({Pid, _}) ->
        {links, Links} = process_info(Pid, links),
        [OsPid || Port <- Links, is_port(Port),
            {os_pid, OsPid} <- [erlang:port_info(Port, os_pid)]]
    end, Resources),
    lists:map(fun(Pid) ->
        ok = tmux_test_fixture:track_process(Fixture, Pid),
        {Pid, tmux_test_fixture:process_identity(Pid)}
    end, Pids).

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
