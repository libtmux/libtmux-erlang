-module(tmux_workspace_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         reconcile/1, ordering/1, pane_capacity/1, zoomed_expansion/1,
         adoption_and_drift/1, destructive_boundaries/1,
         failed_prefix/1, cancellation/1, metadata_cancellation/1]).

%% Outer: real owned tmux, persistent intent, conflict and cancellation evidence.
all() -> [reconcile, ordering, pane_capacity, zoomed_expansion,
          adoption_and_drift, destructive_boundaries, failed_prefix, cancellation,
          metadata_cancellation].
init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang_workspace),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Value -> Value end,
    [{executable, list_to_binary(Executable)} | Config].
end_per_suite(_) -> ok = application:stop(libtmux_erlang_workspace),
    ok = application:stop(libtmux_erlang).

reconcile(Config) -> with_workspace(Config, fun(Server, _Fixture, Dir, File) ->
    D = desired(Dir, 2), write(File, D),
    {ok, Plan} = tmux_workspace_plan:new(File, Server, #{}),
    Output = filename:join(Dir, <<"plan.json">>),
    ok = tmux_workspace_plan:write(Plan, Output),
    {ok, Plan} = tmux_workspace_plan:read(Output),
    {ok, #{completed := Completed}} = tmux_workspace_apply:run(Plan, Server, #{}),
    true = length(Completed) >= 5,
    {ok, Empty} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Empty),
    {ok, Empty} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, #{completed := []}} = tmux_workspace_apply:run(Empty, Server, #{}),
    [S] = maps:get(sessions, D), [W] = maps:get(windows, S),
    [P1, P2] = maps:get(panes, W),
    Updated = D#{sessions => [S#{name => <<"renamed">>, windows => [W#{panes => [
        P1, P2#{argv => [<<"/bin/cat">>, <<"-u">>]}]}]}]},
    write(File, Updated),
    {ok, Update} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_workspace_apply:run(Update, Server, #{}),
    {ok, Settled} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Settled),
    Reduced = Updated#{sessions => [S#{name => <<"renamed">>,
        windows => [W#{panes => [P1]}]}]},
    write(File, Reduced),
    {ok, Remove} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_workspace_apply:run(Remove, Server, #{}),
    {ok, Final} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Final)
end).

ordering(Config) -> with_workspace(Config, fun(Server, _Fixture, Dir, File) ->
    D = desired(Dir, 3), [S] = maps:get(sessions, D), [W] = maps:get(windows, S),
    [P0, P1, P2] = maps:get(panes, W),
    Extra = W#{key => <<"w2">>, name => <<"second">>, panes => [P0#{key => <<"q0">>}]},
    Initial = D#{sessions => [S#{windows => [W, Extra]}]},
    write(File, Initial), {ok, Plan} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_workspace_apply:run(Plan, Server, #{}),
    {ok, Empty} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Empty),
    Reordered = D#{sessions => [S#{windows => [Extra, W#{panes => [P2, P0, P1]}]}]},
    write(File, Reordered), {ok, Update} = tmux_workspace_plan:new(File, Server, #{}),
    Ops = [maps:get(<<"op">>, X) || X <- maps:get(<<"steps">>,
        tmux_workspace_plan:to_map(Update))],
    true = lists:member(<<"swap_panes">>, Ops),
    true = lists:member(<<"swap_windows">>, Ops),
    {ok, _} = tmux_workspace_apply:run(Update, Server, #{}),
    {ok, Settled} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Settled)
end).

pane_capacity(Config) -> with_workspace(Config, fun(Server, _Fixture, Dir, File) ->
    write(File, desired(Dir, 8)),
    {ok, Plan} = tmux_workspace_plan:new(File, Server, #{}),
    Result = tmux_workspace_apply:run(Plan, Server, #{}),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    case Result of
        {error, _} -> ct:pal("Pane dimensions at failure: ~p", [
            [{tmux_model:get(id, P), tmux_model:get(width, P),
              tmux_model:get(height, P)} || P <- tmux_snapshot:panes(Snapshot)]]);
        _ -> ok
    end,
    {ok, _} = Result,
    8 = length(tmux_snapshot:panes(Snapshot)),
    {ok, Settled} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Settled)
end).

zoomed_expansion(Config) -> with_workspace(Config, fun(Server, Fixture, Dir, File) ->
    write(File, desired(Dir, 2)),
    {ok, Initial} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, #{bindings := Bindings}} = tmux_workspace_apply:run(Initial, Server, #{}),
    <<"pane:", First/binary>> = maps:get(<<"p0">>, Bindings),
    <<"pane:", Other/binary>> = maps:get(<<"p1">>, Bindings),
    <<"window:", Window/binary>> = maps:get(<<"w">>, Bindings),
    lists:foreach(fun(Args) ->
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture, Args)
    end, [[<<"select-layout">>, <<"-t">>, Window, <<"even-horizontal">>],
        [<<"set-window-option">>, <<"-t">>, Window, <<"pane-border-status">>, <<"top">>],
        [<<"resize-pane">>, <<"-t">>, First, <<"-x">>, <<"1">>],
        [<<"resize-pane">>, <<"-t">>, First, <<"-Z">>]]),
    write(File, desired(Dir, 8)),
    {ok, Plan} = tmux_workspace_plan:new(File, Server, #{}),
    [#{<<"anchor">> := #{<<"target">> := <<"pane:", Other/binary>>}} | _] =
        [Step || #{<<"op">> := <<"create_pane">>} = Step <-
            maps:get(<<"steps">>, tmux_workspace_plan:to_map(Plan))],
    {ok, _} = tmux_workspace_apply:run(Plan, Server, #{}),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    8 = length(tmux_snapshot:panes(Snapshot)),
    {ok, Settled} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Settled)
end).

adoption_and_drift(Config) -> with_workspace(Config, fun(Server, _Fixture, Dir, File) ->
    {ok, Foreign} = tmux_session:create(Server, #{name => <<"foreign">>,
        launch => #{argv => [<<"/bin/cat">>]}}),
    ForeignId = tmux_model:get(id, Foreign),
    {ok, _} = tmux_session:create(Server, #{name => <<"workspace">>,
        window_name => <<"api">>, launch => #{argv => [<<"/bin/cat">>]}}),
    D = desired(Dir, 1), write(File, D),
    {error, #{code := plan_conflict, reason := name_in_use}} =
        tmux_workspace_plan:new(File, Server, #{}),
    {ok, Plan} = tmux_workspace_plan:new(File, Server,
        #{adopt => [<<"s">>, <<"w">>, <<"p0">>]}),
    {ok, _} = tmux_workspace_apply:run(Plan, Server, #{}),
    {ok, _} = tmux_session:get(Server, ForeignId),
    {ok, Snapshot} = tmux_server:snapshot(Server),
    {ok, Ours} = tmux_select:one(#{name => <<"workspace">>},
        tmux_select:sessions(Snapshot)),
    {ok, DriftPlan} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_session:rename(Ours, <<"manual-change">>),
    {error, #{code := plan_conflict, completed := []}} =
        tmux_workspace_apply:run(DriftPlan, Server, #{}),
    {ok, _} = tmux_session:rename(Ours, <<"workspace">>),
    {ok, Fresh} = tmux_server:snapshot(Server),
    {ok, FreshSession} = tmux_select:one(#{id => tmux_model:get(id, Ours)},
        tmux_select:sessions(Fresh)),
    [OwnedWindow] = unwrap(tmux_snapshot:related(windows,
        FreshSession, Fresh)),
    [Pane] = unwrap(tmux_snapshot:related(panes, OwnedWindow, Fresh)),
    {ok, _} = tmux_option:unset(Pane, <<"@libtmux_workspace">>),
    {error, #{code := plan_conflict}} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_session:get(Server, ForeignId)
end).

failed_prefix(Config) -> with_workspace(Config, fun(Server, _Fixture, Dir, File) ->
    D = desired(Dir, 1), [S] = maps:get(sessions, D), [W] = maps:get(windows, S),
    Broken = #{key => <<"broken-window">>, name => <<"broken">>, panes => [
        #{key => <<"broken-pane">>, cwd => Dir,
            argv => [<<"/definitely-missing-workspace-executable">>]}]},
    write(File, D#{sessions => [S#{windows => [W, Broken]}]}),
    {ok, Plan} = tmux_workspace_plan:new(File, Server, #{}),
    {error, #{completed := [#{number := 1}], step := 2,
              bindings := #{<<"s">> := SessionRef}}} =
        tmux_workspace_apply:run(Plan, Server, #{}),
    <<"session:", Id/binary>> = SessionRef,
    {ok, _} = tmux_session:get(Server, Id)
end).

destructive_boundaries(Config) -> with_workspace(Config, fun(Server, Fixture, Dir, File) ->
    Original = desired(Dir, 1), write(File, Original),
    {ok, Initial} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, #{bindings := Bindings}} = tmux_workspace_apply:run(Initial, Server, #{}),
    <<"window:", WindowId/binary>> = maps:get(<<"w">>, Bindings),
    <<"session:", SessionId/binary>> = maps:get(<<"s">>, Bindings),
    {ok, Window} = tmux_window:get(Server, WindowId),
    {ok, Unmanaged} = tmux_pane:split(Window,
        #{launch => #{argv => [<<"/bin/cat">>]}}),
    UnmanagedId = tmux_model:get(id, Unmanaged),
    Replacement = #{version => 1, id => <<"workspace-tests">>, endpoint => <<"dev">>,
        sessions => [#{key => <<"replacement">>, name => <<"replacement">>, windows => [
            #{key => <<"new-window">>, name => <<"new">>, panes => [
                #{key => <<"new-pane">>, cwd => Dir, argv => [<<"/bin/cat">>]}]}]}]},
    write(File, Replacement),
    {error, #{code := plan_conflict, reason := unmanaged_descendant}} =
        tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_session:get(Server, SessionId),
    {ok, _} = tmux_pane:get(Server, UnmanagedId),
    {ok, Unchanged} = tmux_server:snapshot(Server),
    false = tmux_select:exists(#{name => <<"replacement">>},
        tmux_select:sessions(Unchanged)),
    {ok, _} = tmux_pane:kill(Unmanaged),
    {ok, Foreign} = tmux_session:create(Server, #{name => <<"borrowed">>,
        launch => #{argv => [<<"/bin/cat">>]}}),
    ForeignId = tmux_model:get(id, Foreign),
    {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"link-window">>, <<"-d">>, <<"-s">>, WindowId, <<"-t">>, <<ForeignId/binary, $:>>]),
    {error, #{code := plan_conflict, reason := shared_window}} =
        tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_window:get(Server, WindowId),
    {ok, _} = tmux_session:get(Server, ForeignId),
    {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"unlink-window">>, <<"-t">>, <<ForeignId/binary, $:, WindowId/binary>>]),
    {ok, Safe} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_workspace_apply:run(Safe, Server, #{}),
    {error, #{code := target_gone}} = tmux_session:get(Server, SessionId),
    {ok, _} = tmux_session:get(Server, ForeignId),
    {ok, Settled} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Settled)
end).

cancellation(Config) -> with_workspace(Config, fun(Server, Fixture, Dir, File) ->
    write(File, desired(Dir, 1)),
    {ok, Plan} = tmux_workspace_plan:new(File, Server, #{}),
    Before = make_ref(), self() ! {tmux_workspace_cancel, Before},
    {error, #{code := cancelled, completed := []}} =
        tmux_workspace_apply:run(Plan, Server, #{cancel => Before}),
    {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"set-hook">>, <<"-g">>, <<"after-new-session">>,
         <<"wait-for -S workspace-entered ; wait-for workspace-release">>]),
    {ok, Wait} = tmux_command:wait_for(<<"workspace-entered">>, wait),
    {ok, Entered} = tmux_operation:start(Server, Wait, #{}),
    Parent = self(), Ref = make_ref(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Parent ! {workspace_result, self(), tmux_workspace_apply:run(
            Plan, Server, #{cancel => Ref})}
    end),
    try
        {ok, #{cleanup := complete}} = tmux_operation:await(Entered, 900),
        Worker ! {tmux_workspace_cancel, Ref},
        receive
            {workspace_result, Worker, {error, #{code := cancelled,
                operation_outcome := unknown, cleanup := complete}}} -> ok
        after 900 -> ct:fail(cancellation_result_missing)
        end,
        receive {'DOWN', Monitor, process, Worker, normal} -> ok
        after 900 -> ct:fail(cancellation_worker_alive)
        end
    after
        exit(Worker, shutdown), erlang:demonitor(Monitor, [flush]),
        {ok, Signal} = tmux_command:wait_for(<<"workspace-release">>, signal),
        {ok, _} = tmux_server:command(Server, Signal, #{})
    end
end).

%% Outer: block three real metadata clients, then cancel and prove retirement.
metadata_cancellation(Config) -> with_workspace(Config, fun(Server, Fixture, Dir, File) ->
    write(File, desired(Dir, 4)),
    {ok, Initial} = tmux_workspace_plan:new(File, Server, #{}),
    {ok, _} = tmux_workspace_apply:run(Initial, Server, #{}),
    {ok, Empty} = tmux_workspace_plan:new(File, Server, #{}),
    #{<<"steps">> := []} = tmux_workspace_plan:to_map(Empty),
    Socket = filename:join(Dir, <<"metadata.sock">>),
    Helper = filename:join(Dir, <<"metadata.py">>),
    ok = file:write_file(Helper, <<
        "import os,socket,sys\n",
        "s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)\n",
        "s.connect(sys.argv[1])\n",
        "s.sendall(str(os.getpid()).encode()+b'\\n')\n",
        "s.recv(1)\n",
        "s.close()\n">>),
    {ok, Listen} = gen_tcp:listen(0, [{ifaddr, {local, binary_to_list(Socket)}},
        binary, {packet, line}, {packet_size, 64}, {active, false}]),
    Token = make_ref(), put(Token, []),
    {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"set-hook">>, <<"-g">>, <<"after-show-options">>,
         <<"run-shell '/usr/bin/python3 ", Helper/binary, $\s, Socket/binary, $'>>]),
    Parent = self(), Cancel = make_ref(),
    {Caller, Monitor} = spawn_monitor(fun() ->
        Parent ! {Token, tmux_workspace_apply:run(Empty, Server, #{cancel => Cancel})}
    end),
    try
        lists:foreach(fun(_) ->
            case gen_tcp:accept(Listen, 900) of
                {ok, Connection} ->
                    put(Token, [Connection | get(Token)]),
                    {ok, Line} = gen_tcp:recv(Connection, 0, 900),
                    Pid = binary_to_integer(string:trim(Line)),
                    ok = tmux_test_fixture:track_process(Fixture, Pid);
                {error, timeout} -> ct:fail({parallel_metadata_reads_missing,
                    length(get(Token))})
            end
        end, lists:seq(1, 3)),
        Caller ! {tmux_workspace_cancel, Cancel},
        lists:foreach(fun(C) -> ok = gen_tcp:send(C, <<"Q">>) end, get(Token)),
        receive {Token, {error, #{code := cancelled, completed := [],
                                  cleanup := complete}}} -> ok
        after 900 -> ct:fail(metadata_cancellation_missing) end,
        receive {'DOWN', Monitor, process, Caller, normal} -> ok
        after 900 -> ct:fail(metadata_caller_alive) end,
        {ok, #{operations := 0}} = tmux_server:status(Server),
        {error, timeout} = gen_tcp:accept(Listen, 0),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        4 = length(tmux_snapshot:panes(Snapshot))
    after
        exit(Caller, kill), erlang:demonitor(Monitor, [flush]),
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"set-hook">>, <<"-ug">>, <<"after-show-options">>]),
        lists:foreach(fun(C) -> ok = gen_tcp:close(C) end, erase(Token)),
        ok = gen_tcp:close(Listen)
    end
end).

with_workspace(Config, Fun) ->
    Dir = filename:join(<<"/tmp">>, <<"ltm-workspace-",
        (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary>>),
    ok = file:make_dir(Dir), ok = file:change_mode(Dir, 8#700),
    try tmux_test_fixture:with_server(proplists:get_value(executable, Config),
        fun(Server, Fixture) -> Fun(Server, Fixture, Dir,
            filename:join(Dir, <<"workspace.json">>)) end)
    after ok = file:del_dir_r(Dir) end.

desired(Dir, Count) ->
    #{version => 1, id => <<"workspace-tests">>, endpoint => <<"dev">>,
      sessions => [#{key => <<"s">>, name => <<"workspace">>, windows => [
        #{key => <<"w">>, name => <<"api">>, layout => <<"tiled">>, panes => [
            #{key => <<"p", (integer_to_binary(I))/binary>>, cwd => Dir,
                argv => [<<"/bin/cat">>]} || I <- lists:seq(0, Count - 1)]}]}]}.
write(File, Document) -> ok = file:write_file(File, json:encode(Document)).
unwrap({ok, Value}) -> Value.
