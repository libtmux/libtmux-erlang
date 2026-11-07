-module(tmux_option_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, scalar_scope/1,
         arrays_and_bytes/1, missing_targets/1, catalogue/1, c_locale/1]).

%% Outer: native option tables and byte round trips need an owned real server.
all() -> [scalar_scope, arrays_and_bytes, missing_targets, catalogue, c_locale].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

c_locale(Config) ->
    Previous = os:getenv("LC_ALL"),
    try
        %% This suite runs serially. Restore the VM-global environment even
        %% when opening fails, so the regression cannot affect later suites.
        true = os:putenv("LC_ALL", "C"),
        with_server(Config, fun(_, Session, _, _, _) ->
            Bytes = <<"caf", 16#c3, 16#a9, 255, $\t, $\n>>,
            {ok, _} = tmux_option:set(Session, <<"@locale">>, Bytes),
            {ok, Bytes} = tmux_option:get(Session, <<"@locale">>, #{}),
            {ok, _} = tmux_option:set(Session, {<<"update-environment">>, 0}, Bytes),
            {ok, Bytes} = tmux_option:get(Session, {<<"update-environment">>, 0}, #{})
        end)
    after
        case Previous of
            false -> true = os:unsetenv("LC_ALL");
            Value -> true = os:putenv("LC_ALL", Value)
        end
    end.

scalar_scope(Config) ->
    with_server(Config, fun(Server, Session, Window, Pane, _) ->
        Global = {session_defaults, Server},
        Name = <<"@workspace-#{pid};">>,
        none = tmux_option:get(Session, Name, #{}),
        {ok, _} = tmux_option:set(Global, Name, <<"global\n">>),
        none = tmux_option:get(Session, Name, #{}),
        {ok, <<"global\n">>} = tmux_option:get(Session, Name, #{inherit => true}),
        {ok, _} = tmux_option:set(Session, Name, <<>>),
        {ok, <<>>} = tmux_option:get(Session, Name, #{inherit => true}),
        {error, #{code := command_error}} =
            tmux_option:set(Session, Name, <<"new">>, #{only_if_unset => true}),
        {ok, _} = tmux_option:set(Session, Name, <<"local">>, #{append => true}),
        {ok, <<"local">>} = tmux_option:get(Session, Name, #{}),
        {ok, _} = tmux_option:unset(Session, Name),
        {ok, <<"global\n">>} = tmux_option:get(Session, Name, #{inherit => true}),
        {ok, _} = tmux_option:set({window_defaults, Server}, Name, <<"window">>),
        {ok, <<"window">>} = tmux_option:get(Pane, Name, #{inherit => true}),
        {ok, _} = tmux_option:set(Window, Name, <<"physical">>),
        {ok, <<"physical">>} = tmux_option:get(Pane, Name, #{inherit => true}),
        {ok, _} = tmux_option:set(Pane, Name, <<"pane">>),
        {ok, <<"pane">>} = tmux_option:get(Pane, Name, #{}),
        {ok, <<"physical">>} = tmux_option:get(Window, Name, #{}),
        {ok, Before} = tmux_option:get({server, Server}, <<"exit-empty">>, #{}),
        {error, #{code := wrong_option_scope}} =
            tmux_option:set(Pane, <<"exit-empty">>, <<"off">>),
        {ok, Before} = tmux_option:get({server, Server}, <<"exit-empty">>, #{}),
        {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
        none = tmux_option:get(Pane, <<"remain-on-exit">>, #{}),
        {ok, <<"on">>} = tmux_option:get(Pane, <<"remain-on-exit">>, #{inherit => true})
    end).

arrays_and_bytes(Config) ->
    with_server(Config, fun(_Server, Session, _, _, _) ->
        Array = <<"update-environment">>,
        none = tmux_option:get(Session, Array, #{}),
        Values = [<<>>, <<"'\"\\~ #;${}%\n\t\r", 7, 8, 11, 12>>,
                  <<"caf", 16#c3, 16#a9>>, <<255, 128, 1, 127>>, <<"~">>,
                  <<";">>, <<"#">>, <<"$">>, <<"{">>, <<"'">>, <<"\"">>,
                  list_to_binary(lists:seq(1, 255))],
        lists:foreach(fun({Index, Value}) ->
            {ok, _} = tmux_option:set(Session, {Array, Index}, Value),
            {ok, Value} = tmux_option:get(Session, {Array, Index}, #{}),
            {ok, _} = tmux_option:set(Session, <<"@bytes">>, Value),
            {ok, Value} = tmux_option:get(Session, <<"@bytes">>, #{})
        end, lists:zip(lists:seq(0, length(Values) - 1), Values)),
        {ok, Entries} = tmux_option:get(Session, Array, #{}),
        Values = [maps:get(I, Entries) || I <- lists:seq(0, length(Values) - 1)],
        none = tmux_option:get(Session, {Array, 100}, #{}),
        {ok, <<>>} = tmux_option:get(Session, {Array, 0}, #{}),
        {ok, _} = tmux_option:set(Session, {Array, 0}, <<"appended">>, #{append => true}),
        {ok, <<"appended">>} = tmux_option:get(Session, {Array, 0}, #{}),
        lists:foreach(fun(Index) -> {ok, _} = tmux_option:unset(Session, {Array, Index}) end,
            lists:seq(0, length(Values) - 1)),
        {ok, #{}} = tmux_option:get(Session, Array, #{}),
        {ok, _} = tmux_option:unset(Session, Array),
        none = tmux_option:get(Session, Array, #{}),
        {ok, Inherited} = tmux_option:get(Session, Array, #{inherit => true}),
        true = map_size(Inherited) > 0
    end).

missing_targets(Config) ->
    with_server(Config, fun(Server, Session, Window, Pane, _) ->
        {ok, _} = tmux_window:kill(Window),
        {error, #{code := target_gone}} = tmux_option:get(Pane, <<"@missing">>, #{}),
        {error, #{code := target_gone}} = tmux_option:set(Window, <<"@value">>, <<"x">>),
        {ok, _} = tmux_session:kill(Session),
        {error, #{code := target_gone}} = tmux_option:get(Session, <<"@missing">>, #{}),
        ok = tmux_server:close(Server),
        {error, #{code := stale_reference}} = tmux_option:unset(Session, <<"@value">>)
    end).

catalogue(Config) ->
    with_server(Config, fun(Server, _, _, _, Fixture) ->
        {ok, Version} = tmux_server:version(Server),
        {ok, Entries} = tmux_option:catalogue(Version),
        lists:foreach(fun({Scope, Flags}) ->
            {ok, #{stdout := Output}} = tmux_test_fixture:command(Fixture,
                [<<"show-options">>, <<"-H">> | Flags]),
            Names = lists:usort([hd(binary:split(hd(binary:split(Line, <<" ">>)), <<"[">>))
                || Line <- binary:split(Output, <<"\n">>, [global]), Line =/= <<>>]),
            Expected = lists:sort([Name || {Name, #{scopes := Scopes}} <- maps:to_list(Entries),
                lists:member(Scope, Scopes)]),
            Expected = Names
        end, [{server, [<<"-s">>]}, {session, [<<"-g">>]},
              {window, [<<"-g">>, <<"-w">>]}])
    end).

with_server(Config, Fun) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, Server} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try
            Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
            {ok, Session} = tmux_session:create(Server, Launch#{name => <<"options">>}),
            {ok, Window} = tmux_window:create(Session, Launch),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            lists:foreach(fun(P) ->
                ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, P))
            end, tmux_snapshot:panes(Snapshot)),
            {ok, Captured} = tmux_snapshot:get(window, tmux_model:get(id, Window), Snapshot),
            {ok, [Pane]} = tmux_snapshot:related(panes, Captured, Snapshot),
            Fun(Server, Session, Window, Pane, Fixture)
        after ok = tmux_server:close(Server)
        end
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end.
