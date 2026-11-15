-module(tmux_pane_exit_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         exit_status/1, waits_for_a_running_pane/1, killed_by_signal/1,
         retention_required/1, deadline/1, vanished_pane/1, invalid_options/1,
         hook_removed/1]).

%% Outer: a pane's exit status and signal exist only on an owned native server.
all() -> [exit_status, waits_for_a_running_pane, killed_by_signal,
          retention_required, deadline, vanished_pane, invalid_options, hook_removed].

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
        lists:foreach(fun({Argv, Expected}) ->
            Pane = job(Window, Fixture, Argv),
            {ok, #{exit := Expected, pane := Dead}} =
                tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}),
            true = tmux_model:get(dead, Dead),
            {ok, _} = tmux_pane:kill(Dead)
        end, [{[<<"/bin/true">>], {status, 0}},
              {[<<"/bin/false">>], {status, 1}},
              {[<<"/bin/sh">>, <<"-c">>, <<"exit 7">>], {status, 7}}])
    end).

waits_for_a_running_pane(Config) ->
    with_window(Config, true, fun(_Server, Window, Fixture) ->
        Pane = job(Window, Fixture, [<<"/bin/cat">>]),
        Self = self(),
        Waiter = spawn_link(fun() ->
            Self ! {done, tmux_pane:wait_exit(Pane, #{deadline_ms => 5000})}
        end),
        {ok, _} = tmux_pane:send_keys(Pane, [{control, <<"d">>}]),
        {ok, #{exit := {status, 0}, pane := Dead}} = receive {done, Result} -> Result
            after 6000 -> ct:fail(waiter_timeout) end,
        unlink(Waiter),
        %% The pane is dead now, so a second call reads the same outcome.
        {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Dead, #{})
    end).

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
        Pane = job(Window, Fixture, [<<"/bin/cat">>]),
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
        Pane = job(Window, Fixture, [<<"/bin/true">>]),
        {ok, #{exit := {status, 0}}} = tmux_pane:wait_exit(Pane, #{deadline_ms => 5000}),
        case tmux_hook:get(Pane, <<"pane-died">>, #{}) of
            none -> ok;
            {ok, Entries} -> 0 = map_size(Entries)
        end
    end).

%% Jobs that end by themselves may be gone before the fixture can read them.
job(Window, Fixture, [<<"/bin/true">>] = Argv) -> job(Window, Fixture, Argv, false);
job(Window, Fixture, [<<"/bin/false">>] = Argv) -> job(Window, Fixture, Argv, false);
job(Window, Fixture, [<<"/bin/sh">> | _] = Argv) -> job(Window, Fixture, Argv, false);
job(Window, Fixture, Argv) -> job(Window, Fixture, Argv, true).

job(Window, Fixture, Argv, Track) ->
    {ok, Pane} = tmux_pane:split(Window, #{launch => #{argv => Argv}}),
    case {Track, tmux_model:get(pid, Pane)} of
        {true, Pid} when is_integer(Pid) -> ok = tmux_test_fixture:track_process(Fixture, Pid);
        _ -> ok
    end,
    Pane.

with_window(Config, Retain, Fun) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config),
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
