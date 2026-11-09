-module(tmux_workspace_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         reconcile/1, ordering/1, adoption_and_drift/1, failed_prefix/1, cancellation/1]).

%% Outer: real owned tmux, persistent intent, conflict and cancellation evidence.
all() -> [reconcile, ordering, adoption_and_drift, failed_prefix, cancellation].
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
