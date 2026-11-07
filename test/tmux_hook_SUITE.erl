-module(tmux_hook_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         arrays_and_effects/1, linked_context/1, automatic_hook/1, missing_session/1]).

%% Outer: stored commands and hook effects need an isolated native daemon.
all() -> [arrays_and_effects, linked_context, automatic_hook, missing_session].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

arrays_and_effects(Config) ->
    with_server(Config, fun(Server, Session, Window, Pane, Link, _) ->
        Name = <<"pane-died">>,
        Global = {window_defaults, Server},
        {ok, G} = command(Session, <<"@order">>, <<"G">>, true),
        {ok, _} = tmux_hook:set(Global, {Name, 9}, G),
        none = tmux_hook:get(Window, Name, #{}),
        {ok, #{9 := _}} = tmux_hook:get(Window, Name, #{inherit => true}),
        {ok, A} = command(Session, <<"@order">>, <<"A">>, true),
        {ok, B} = command(Session, <<"@order">>, <<"B">>, true),
        {ok, _} = tmux_hook:set(Window, {Name, 7}, A),
        {ok, _} = tmux_hook:append(Window, Name, B),
        {ok, Entries} = tmux_hook:get(Window, Name, #{}),
        [0, 7] = lists:sort(maps:keys(Entries)),
        {ok, _} = tmux_option:set(Session, <<"@order">>, <<>>),
        {ok, _} = tmux_hook:run(Link, Name),
        {ok, <<"BA">>} = tmux_option:get(Session, <<"@order">>, #{}),
        {ok, Bad} = tmux_command:raw(<<"not-a-tmux-command">>, []),
        {error, #{code := command_error}} = tmux_hook:set(Window, {Name, 7}, Bad),
        {ok, Entries} = tmux_hook:get(Window, Name, #{}),
        {error, #{code := command_error}} = tmux_hook:set(Pane, {Name, 0}, Bad),
        {ok, #{}} = tmux_hook:get(Pane, Name, #{inherit => true}),
        {ok, _} = tmux_hook:unset(Pane, Name),
        none = tmux_hook:get(Pane, {Name, 100}, #{}),
        {ok, _} = tmux_hook:clear(Window, Name),
        {ok, #{}} = tmux_hook:get(Window, Name, #{inherit => true}),
        {ok, _} = tmux_hook:run(Link, Name),
        {ok, <<"BA">>} = tmux_option:get(Session, <<"@order">>, #{}),
        {ok, _} = tmux_hook:unset(Window, Name),
        {ok, _} = tmux_hook:run(Link, Name),
        {ok, <<"BAG">>} = tmux_option:get(Session, <<"@order">>, #{}),
        Bytes = <<"$HOME ${USER} ~root #{session_id} #[red];\n  #end\n",
            (list_to_binary(lists:seq(1, 255)))/binary>>,
        {ok, Literal} = command(Session, <<"@bytes">>, Bytes, false),
        {ok, _} = tmux_hook:set(Window, {Name, 31}, Literal),
        {ok, Stored} = tmux_hook:get(Window, {Name, 31}, #{}),
        {ok, Copy} = tmux_command:raw(<<"set-hook">>, [<<"-w">>, <<"-t">>,
            tmux_model:get(id, Window), <<"--">>, <<Name/binary, "[32]">>, Stored]),
        {ok, _} = tmux_server:command(Server, Copy, #{}),
        {ok, _} = tmux_hook:unset(Window, {Name, 31}),
        {ok, _} = tmux_hook:run({pane, Pane, Link}, Name),
        {ok, Bytes} = tmux_option:get(Session, <<"@bytes">>, #{}),
        {ok, _} = tmux_hook:unset(Window, {Name, 32}),
        {ok, #{}} = tmux_hook:get(Window, Name, #{}),
        {ok, _} = tmux_hook:clear(Global, Name),
        {ok, #{}} = tmux_hook:get(Global, Name, #{}),
        ok = tmux_server:close(Server),
        {error, #{code := stale_reference}} = tmux_hook:unset(Window, Name)
    end).

linked_context(Config) ->
    with_server(Config, fun(Server, _Session, Window, Pane, Link, Fixture) ->
        Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
        {ok, Other} = tmux_session:create(Server, Launch#{name => <<"other">>}),
        {ok, _} = tmux_window_link:link(Link, Other, #{index => 7}),
        {ok, _} = tmux_window_link:link(Link, Other, #{index => 9}),
        OtherId = tmux_model:get(id, Other),
        {ok, Seven} = tmux_window_link:get(Server, OtherId, 7),
        {ok, Nine} = tmux_window_link:get(Server, OtherId, 9),
        {ok, Context} = tmux_command:raw(<<"display-message">>, [<<"-p">>,
            <<"#{session_id}|#{window_id}|#{window_index}|#{pane_id}">>]),
        Name = <<"pane-died">>,
        {ok, _} = tmux_hook:set(Window, {Name, 0}, Context),
        WindowId = tmux_model:get(id, Window),
        PaneId = tmux_model:get(id, Pane),
        lists:foreach(fun({Current, Index}) ->
            {ok, #{stdout := Output}} = tmux_hook:run({pane, Pane, Current}, Name),
            Expected = <<OtherId/binary, $|, WindowId/binary, $|, Index/binary,
                $|, PaneId/binary, $\n>>,
            Expected = Output
        end, [{Seven, <<"7">>}, {Nine, <<"9">>}]),
        {error, #{code := invalid_hook_context}} = tmux_hook:run(Window, Name),
        {ok, _} = tmux_window_link:move(Seven, Other, #{index => 12}),
        {error, #{code := stale_link}} = tmux_hook:run(Seven, Name),
        {ok, _} = tmux_pane:split(Pane, Launch),
        {ok, OtherLink} = tmux_window_link:get(Server, OtherId, 0),
        OtherWindowId = tmux_model:get(window_id, OtherLink),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        [Destination] = [P || P <- tmux_snapshot:panes(Snapshot),
            tmux_model:get(window_id, P) =:= OtherWindowId],
        {ok, _} = tmux_pane:join(Pane, Destination, #{}),
        {error, #{code := pane_link_mismatch}} =
            tmux_hook:run({pane, Pane, Nine}, Name),
        track(Server, Fixture)
    end).

automatic_hook(Config) ->
    with_server(Config, fun(Server, Session, _, Pane, _, Fixture) ->
        Name = <<"after-split-window">>,
        Channel = <<"hook-observed">>,
        {ok, Mark} = command(Session, <<"@hook">>, <<"split complete">>, false),
        {ok, Signal} = tmux_command:wait_for(Channel, signal),
        {ok, Wait} = tmux_command:wait_for(Channel, wait),
        {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
        {ok, _} = tmux_hook:set(Session, {Name, 4}, [Mark, Signal]),
        {ok, _} = tmux_pane:split(Pane,
            #{launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, #{cleanup := complete}} = tmux_operation:await(Operation, 900),
        {ok, <<"split complete">>} = tmux_option:get(Session, <<"@hook">>, #{}),
        {ok, _} = tmux_hook:unset(Session, Name),
        none = tmux_hook:get(Session, Name, #{}),
        track(Server, Fixture)
    end).


missing_session(Config) ->
    with_server(Config, fun(Server, Session, _, _, _, Fixture) ->
        {ok, Other} = tmux_session:create(Server,
            #{name => <<"survivor">>, launch => #{argv => [<<"/bin/cat">>]}}),
        Name = <<"after-split-window">>,
        {ok, Marker} = tmux_command:raw(<<"display-message">>,
            [<<"-p">>, <<"wrong-session-executed">>]),
        {ok, _} = tmux_hook:set(Other, {Name, 0}, Marker),
        {ok, _} = tmux_session:kill(Session),
        {error, #{code := target_gone}} = tmux_hook:run(Session, Name),
        track(Server, Fixture)
    end).

command(Session, Name, Value, Append) ->
    Flags = case Append of true -> [<<"-a">>]; false -> [] end,
    tmux_command:raw(<<"set-option">>, Flags ++ [<<"-t">>,
        tmux_model:get(id, Session), <<"--">>, Name, Value]).

track(Server, Fixture) ->
    {ok, Snapshot} = tmux_server:snapshot(Server),
    lists:foreach(fun(Pane) ->
        ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, Pane))
    end, tmux_snapshot:panes(Snapshot)).

with_server(Config, Fun) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, Server} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try
            {ok, Session} = tmux_session:create(Server,
                #{name => <<"hooks">>, launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            [Window] = tmux_snapshot:windows(Snapshot),
            [Pane] = tmux_snapshot:panes(Snapshot),
            [Link] = tmux_snapshot:window_links(Snapshot),
            track(Server, Fixture),
            Fun(Server, Session, Window, Pane, Link, Fixture)
        after ok = tmux_server:close(Server)
        end
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end.
