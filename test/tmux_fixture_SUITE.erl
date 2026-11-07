-module(tmux_fixture_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         command_failure_and_cleanup/1, owner_death/1, cancelled_client/1]).

%% Outer: owned foreground tmux, pane descendants, and cancellation aftereffects.
all() -> [command_failure_and_cleanup, owner_death, cancelled_client].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Binary = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    true = is_list(Binary),
    [{tmux, list_to_binary(Binary)} | Config].

end_per_suite(_Config) -> ok = application:stop(libtmux_erlang).

command_failure_and_cleanup(Config) ->
    {ok, Fixture} = tmux_test_fixture:start(proplists:get_value(tmux, Config)),
    Info = tmux_test_fixture:info(Fixture),
    {ok, Identity} = tmux_identity:observe(maps:get(server_pid, Info)),
    try
        {ok, #{exit_status := 0, stdout := <<"$0\n">>}} = tmux_test_fixture:command(Fixture,
            [<<"new-session">>, <<"-d">>, <<"-P">>, <<"-F">>, <<"#{session_id}">>,
             <<"-s">>, <<"fixture">>, <<"/bin/cat">>]),
        {ok, #{stdout := PidText, exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"display-message">>, <<"-p">>, <<"#{pane_pid}">>]),
        PanePid = binary_to_integer(string:trim(PidText)),
        PaneIdentity = tmux_test_fixture:process_identity(PanePid),
        {ok, #{exit_status := 1, stderr := Error, cleanup := complete}} =
            tmux_test_fixture:command(Fixture, [<<"no-such-command">>]),
        true = byte_size(Error) > 0,
        {ok, #{stdout := <<"fixture\n">>, exit_status := 0}} = tmux_test_fixture:command(
            Fixture, [<<"list-sessions">>, <<"-F">>, <<"#{session_name}">>]),
        ok = tmux_test_fixture:close(Fixture),
        {error, #{code := stale_server}} = tmux_identity:check(Identity, maps:get(server_pid, Info)),
        false = tmux_test_fixture:same_process(PanePid, PaneIdentity),
        retired(Info)
    after
        tmux_test_fixture:ensure_closed(Fixture)
    end.

owner_death(Config) ->
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, Fixture} = tmux_test_fixture:start(proplists:get_value(tmux, Config)),
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"new-session">>, <<"-d">>, <<"/bin/cat">>]),
        Parent ! {ready, self(), Fixture, tmux_test_fixture:info(Fixture)},
        receive finish -> ok end
    end),
    receive
        {ready, Owner, Fixture, Info} ->
            Monitor = monitor(process, Fixture),
            exit(Owner, kill),
            receive {'DOWN', Monitor, process, Fixture, normal} -> retired(Info)
            after 900 -> ct:fail(fixture_owner_cleanup_timeout)
            end
    after 900 -> exit(Owner, kill), ct:fail(fixture_start_timeout)
    end.

cancelled_client(Config) ->
    {ok, Fixture} = tmux_test_fixture:start(proplists:get_value(tmux, Config)),
    try
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"new-session">>, <<"-d">>, <<"/bin/cat">>]),
        {ok, Handle} = tmux_test_fixture:start_command(Fixture,
            [<<"wait-for">>, <<"never-signalled">>]),
        {ok, _} = tmux_transport:await_started(Handle, 900),
        {ok, cancel_requested} = tmux_transport:cancel(Handle),
        {error, #{code := cancelled, cleanup := complete, outcome := unknown}} =
            tmux_transport:await(Handle, 900),
        ok = tmux_transport:close(Handle),
        {ok, #{stdout := <<"$0\n">>, exit_status := 0}} = tmux_test_fixture:command(
            Fixture, [<<"list-sessions">>, <<"-F">>, <<"#{session_id}">>]),
        Info = tmux_test_fixture:info(Fixture),
        ok = tmux_test_fixture:close(Fixture),
        retired(Info)
    after
        tmux_test_fixture:ensure_closed(Fixture)
    end.

retired(#{directory := Directory, server_pid := Server, server_identity := Identity}) ->
    false = filelib:is_dir(Directory),
    false = tmux_test_fixture:same_process(Server, Identity).
