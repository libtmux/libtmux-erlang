-module(tmux_option_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, scalar_scope/1,
         arrays_and_bytes/1, missing_targets/1, catalogue/1, c_locale/1,
         scalar_batches/1, batch_target_changes/1]).

%% Outer: native option tables and byte round trips need an owned real server.
all() -> [scalar_scope, arrays_and_bytes, missing_targets, catalogue, c_locale,
          scalar_batches, batch_target_changes].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

scalar_batches(Config) ->
    with_server(Config, fun(Server, Session, Window, Pane, Fixture) ->
        Rows = [Session, Window, Pane],
        Name = <<"@batch">>,
        {ok, _} = tmux_option:set({session_defaults, Server}, Name, <<"session">>),
        {ok, _} = tmux_option:set({window_defaults, Server}, Name, <<"window">>),
        {ok, [none, none, none]} = tmux_option:get_many(Rows, Name, #{}),
        {ok, [<<"session">>, <<"window">>, <<"window">>]} =
            tmux_option:get_many(Rows, Name, #{inherit => true}),
        {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
        {ok, [<<"on">>, none]} =
            tmux_option:get_many([Window, Pane], <<"remain-on-exit">>, #{}),
        {ok, [<<"on">>, <<"on">>]} = tmux_option:get_many([Window, Pane],
            <<"remain-on-exit">>, #{inherit => true}),
        Values = [<<>>, <<"__ltm_option_end_1:%1\n\r\t$HOME \\",
            "'\"#{pid};">>, list_to_binary(lists:seq(1, 255))],
        lists:foreach(fun({Row, Value}) ->
            {ok, _} = tmux_option:set(Row, Name, Value)
        end, lists:zip(Rows, Values)),
        {ok, Values} = tmux_option:get_many(Rows, Name, #{}),
        %% Seven maximally escaped 32 KiB values fit the aggregate output
        %% bound. Load fixture configuration over stdin to avoid argv limits.
        Worst = binary:copy(<<1>>, 32768),
        Id = tmux_model:get(id, Pane),
        {ok, Source} = tmux_command:source_file(stdin, #{}),
        Text = <<"set-option -p -t ", Id/binary, " @batch \"",
            (binary:copy(<<"\\001">>, 32768))/binary, "\"\n">>,
        {ok, _} = tmux_server:command(Server, Source, #{stdin => Text}),
        Expected = lists:duplicate(7, Worst),
        {ok, Expected} = tmux_option:get_many(lists:duplicate(7, Pane), Name, #{}),
        {ok, Other} = tmux_server:open(#{executable => proplists:get_value(executable, Config),
            socket_path => maps:get(socket, tmux_test_fixture:info(Fixture))}),
        try
            {ok, Snapshot} = tmux_server:snapshot(Other),
            [Foreign | _] = tmux_snapshot:panes(Snapshot),
            Trace = trace:session_create(batch_owners, self(), []),
            try
                1 = trace:function(Trace, {tmux_server, command, 3}, true, [call_count]),
                {error, #{code := different_owner}} =
                    tmux_option:get_many([Pane, Foreign], Name, #{}),
                {call_count, 0} = trace:info(Trace, {tmux_server, command, 3}, call_count)
            after true = trace:session_destroy(Trace) end
        after ok = tmux_server:close(Other) end
    end).

batch_target_changes(Config) ->
    with_server(Config, fun(Server, Session, Window, Pane, Fixture) ->
        Hook = fun(Command) -> tmux_test_fixture:command(Fixture,
            [<<"set-hook">>, <<"-g">>, <<"after-show-options">>, Command]) end,
        {ok, _} = Hook(<<"display-message -p unexpected-hook-output">>),
        try
            {error, #{code := invalid_observation, outcome := success,
                      cleanup := complete}} = tmux_option:get_many([Pane], <<"@v">>, #{})
        after
            {ok, _} = tmux_test_fixture:command(Fixture,
                [<<"set-hook">>, <<"-ug">>, <<"after-show-options">>])
        end,
        %% Delete one pane while its window remains linked. On older tmux,
        %% a removed sole-pane window can retain its pane through queue refs.
        {ok, _} = tmux_pane:split(Pane, #{launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        lists:foreach(fun(P) ->
            ok = tmux_test_fixture:track_process(Fixture, tmux_model:get(pid, P))
        end, tmux_snapshot:panes(Snapshot)),
        Id = tmux_model:get(id, Pane),
        {ok, _} = Hook(<<"kill-pane -t ", Id/binary>>),
        try
            {error, #{code := target_gone, cleanup := complete}} =
                tmux_option:get_many([Pane], <<"@v">>, #{})
        after
            {ok, _} = tmux_test_fixture:command(Fixture,
                [<<"set-hook">>, <<"-ug">>, <<"after-show-options">>])
        end,
        {error, #{code := target_gone, index := 2, cleanup := complete}} =
            tmux_option:get_many([Session, Pane, Window], <<"@v">>, #{})
    end).

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
                  <<"$HOME ${HOME} \\$HOME \\\\$HOME">>,
                  list_to_binary(lists:seq(1, 255))],
        lists:foreach(fun({Index, Value}) ->
            {ok, _} = tmux_option:set(Session, {Array, Index}, Value),
            {ok, Value} = tmux_option:get(Session, {Array, Index}, #{}),
            {ok, _} = tmux_option:set(Session, <<"@bytes">>, Value),
            {ok, Value} = tmux_option:get(Session, <<"@bytes">>, #{})
        end, lists:zip(lists:seq(0, length(Values) - 1), Values)),
        {ok, Entries} = tmux_option:get(Session, Array, #{}),
        Values = [maps:get(I, Entries) || I <- lists:seq(0, length(Values) - 1)],
        lists:foreach(fun(Name) ->
            {ok, _} = tmux_option:set(Session, Name, <<"literal $HOME\\r">>),
            {ok, <<"literal $HOME\\r">>} = tmux_option:get(Session, Name, #{})
        end, [<<"@with space #{pid}\n">>, <<"@caf", 195, 169, 13, 255>>,
              <<"@${HOME}\\$HOME">>, <<$@, 244, 144, 128, 128>>]),
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
