-module(tmux_topology_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         physical_moves/1, contextual_breaks/1]).

%% Outer: topology assertions require owned live servers and process retirement.
all() -> [physical_moves, contextual_breaks].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

physical_moves(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {Session0, Window0, Pane0, _} = base(Server, Fixture, <<"source">>),
        {ok, Pane1} = tmux_pane:split(Pane0, #{launch => #{argv => [<<"/bin/cat">>]}}),
        ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane1)),
        {_, Window1, Pane2, _} = base(Server, Fixture, <<"destination">>),
        Id1 = tmux_model:get(id, Pane1),
        Pid1 = tmux_model:get(pid, Pane1),
        W0 = tmux_model:get(id, Window0),
        W1 = tmux_model:get(id, Window1),
        {ok, Before} = tmux_server:snapshot(Server),
        {ok, _} = tmux_pane:join(Pane1, Pane2,
            #{direction => horizontal, size => {percent, 40}, before => true}),
        {ok, Joined} = tmux_pane:get(Server, Id1),
        W1 = tmux_model:get(window_id, Joined),
        Pid1 = tmux_model:get(pid, Joined),
        {ok, Old} = tmux_snapshot:get(pane, Id1, Before),
        W0 = tmux_model:get(window_id, Old),
        {ok, _} = tmux_pane:move(Pane1, Pane2,
            #{direction => vertical, size => {cells, 5}}),
        {ok, Moved} = tmux_pane:get(Server, Id1),
        W1 = tmux_model:get(window_id, Moved),
        1 = tmux_model:get(index, Moved),
        {error, #{code := same_pane}} = tmux_pane:join(Pane1, Pane1, #{}),
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"resize-pane">>, <<"-Z">>, <<"-t">>, tmux_model:get(id, Pane2)]),
        {ok, _} = tmux_pane:swap(Pane1, Pane0, #{zoom => true}),
        {ok, Swapped} = tmux_pane:get(Server, Id1),
        W0 = tmux_model:get(window_id, Swapped),
        Pid1 = tmux_model:get(pid, Swapped),
        {ok, OtherPane} = tmux_pane:get(Server, tmux_model:get(id, Pane0)),
        W1 = tmux_model:get(window_id, OtherPane),
        {ok, #{stdout := <<"1\n">>}} = tmux_test_fixture:command(Fixture,
            [<<"display-message">>, <<"-p">>, <<"-t">>, W1, <<"#{window_zoomed_flag}">>]),
        {ok, _} = tmux_pane:swap(Pane2, Pane2, #{}),
        {ok, #{stdout := <<"0\n">>}} = tmux_test_fixture:command(Fixture,
            [<<"display-message">>, <<"-p">>, <<"-t">>, W1, <<"#{window_zoomed_flag}">>]),
        #{socket := Socket, executable := Executable} = tmux_test_fixture:info(Fixture),
        {ok, OtherOwner} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try
            {ok, Foreign} = tmux_pane:get(OtherOwner, tmux_model:get(id, Pane2)),
            {error, #{code := different_owner}} = tmux_pane:move(Pane1, Foreign, #{})
        after ok = tmux_server:close(OtherOwner)
        end,
        {ok, _} = tmux_session:kill(Session0),
        {error, #{code := target_gone}} = tmux_pane:move(Pane1, Pane2, #{})
    end).

contextual_breaks(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {Session0, Window0, Pane0, Link0} = base(Server, Fixture, <<"links-source">>),
        {Session1, _, _, _} = base(Server, Fixture, <<"links-other">>),
        S0 = tmux_model:get(id, Session0),
        S1 = tmux_model:get(id, Session1),
        W0 = tmux_model:get(id, Window0),
        Id0 = tmux_model:get(id, Pane0),
        {ok, _} = tmux_window_link:link(Link0, Session0, #{index => 7}),
        {ok, _} = tmux_window_link:link(Link0, Session1, #{index => 8}),
        {ok, FromOther} = tmux_window_link:get(Server, S1, 8),
        Name = <<"break #{pid}; $HOME">>,
        {ok, _} = tmux_pane:break(Pane0, FromOther, Session0, #{index => 9, name => Name}),
        {ok, Single} = tmux_pane:get(Server, Id0),
        W0 = tmux_model:get(window_id, Single),
        {error, #{code := target_gone}} = tmux_window_link:get(Server, S1, 8),
        {ok, Duplicate} = tmux_window_link:get(Server, S0, 7),
        {ok, Destination} = tmux_window_link:get(Server, S0, 9),
        W0 = tmux_model:get(window_id, Destination),
        {ok, Named} = tmux_window:get(Server, W0),
        {ok, Version} = tmux_server:version(Server),
        StoredName = case tmux_version:at_least(Version, {3, 5}) of
            true -> Name;
            false -> <<"break #{pid}; \\$HOME">>
        end,
        StoredName = tmux_model:get(name, Named),
        {ok, Pane1} = tmux_pane:split(Pane0, #{launch => #{argv => [<<"/bin/cat">>]}}),
        Id1 = tmux_model:get(id, Pane1),
        Pid1 = tmux_model:get(pid, Pane1),
        ok = tmux_test_fixture:track_process(Fixture, Pid1),
        {ok, Before} = tmux_server:snapshot(Server),
        {ok, _} = tmux_pane:break(Pane1, Duplicate, Session1, #{index => 6, detach => false}),
        {ok, Current} = tmux_pane:get(Server, Id1),
        W2 = tmux_model:get(window_id, Current),
        true = W2 =/= W0,
        Pid1 = tmux_model:get(pid, Current),
        {ok, BrokenLink} = tmux_window_link:get(Server, S1, 6),
        W2 = tmux_model:get(window_id, BrokenLink),
        true = tmux_model:get(active, BrokenLink),
        {ok, StillLinked} = tmux_window_link:get(Server, S0, 7),
        W0 = tmux_model:get(window_id, StillLinked),
        {ok, Captured} = tmux_snapshot:get(pane, Id1, Before),
        W0 = tmux_model:get(window_id, Captured),
        {error, #{code := pane_link_mismatch}} =
            tmux_pane:break(Pane1, Link0, Session1, #{index => 12}),
        {error, #{code := stale_link}} =
            tmux_pane:break(Pane0, FromOther, Session1, #{index => 12}),
        {error, #{code := command_error}} = tmux_pane:break(Pane1, BrokenLink, Session0,
            #{index => tmux_model:get(index, Link0)}),
        {ok, Unmoved} = tmux_pane:get(Server, Id1),
        W2 = tmux_model:get(window_id, Unmoved),
        {ok, _} = tmux_window_link:link(BrokenLink, Session0, #{index => 11}),
        {ok, _} = tmux_pane:join(Pane1, Pane0, #{}),
        {error, #{code := target_gone}} = tmux_window:get(Server, W2),
        {error, #{code := target_gone}} = tmux_window_link:get(Server, S0, 11),
        {error, #{code := target_gone}} = tmux_window_link:get(Server, S1, 6),
        {ok, _} = tmux_session:kill(Session1),
        {ok, StillRunning} = tmux_pane:get(Server, Id1),
        W0 = tmux_model:get(window_id, StillRunning),
        Pid1 = tmux_model:get(pid, StillRunning),
        {error, #{code := target_gone}} =
            tmux_pane:break(Pane0, Duplicate, Session1, #{index => 12})
    end).

base(Server, Fixture, Name) ->
    {ok, Session} = tmux_session:create(Server,
        #{name => Name, launch => #{argv => [<<"/bin/cat">>]}}),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    {ok, Link} = tmux_select:one(#{session_id => tmux_model:get(id, Session)},
        tmux_select:window_links(Snapshot)),
    {ok, Window} = tmux_snapshot:related(window, Link, Snapshot),
    {ok, [Pane]} = tmux_snapshot:related(panes, Window, Snapshot),
    ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane)),
    {Session, Window, Pane, Link}.

with_server(Config, Fun) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), Fun).
