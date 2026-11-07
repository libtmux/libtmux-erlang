-module(tmux_domain_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, creation_and_identity/1,
         launch_and_input/1, capture_bytes/1, linked_snapshot/1, snapshot_limits/1,
         geometry/1, membership_actions/1]).

%% Outer: public domain calls, literal values, explicit binding and owned teardown.
all() -> [creation_and_identity, launch_and_input, capture_bytes,
          linked_snapshot, snapshot_limits, geometry, membership_actions].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Path = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Value -> Value
    end,
    [{executable, list_to_binary(Path)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

creation_and_identity(Config) ->
    with_server(Config, fun(Server, _) ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"api-#{pid};">>, width => 100, height => 30}),
        <<"api-#{pid};">> = tmux_model:get(name, Session),
        Id = tmux_model:get(id, Session),
        {ok, Detached} = tmux_model:session(#{id => Id}),
        {error, #{code := detached_reference}} = tmux_session:rename(Detached, <<"invalid">>),
        {ok, Bound} = tmux_server:bind(Server, Detached),
        {ok, _} = tmux_session:rename(Bound, <<"renamed-#{pid};">>),
        {ok, Renamed} = tmux_session:get(Server, Id),
        <<"renamed-#{pid};">> = tmux_model:get(name, Renamed),
        <<"api-#{pid};">> = tmux_model:get(name, Session),
        {ok, Window} = tmux_window:create(Session, #{name => <<"win-#{pane_id}%s;">>}),
        <<"win-#{pane_id}%s;">> = tmux_model:get(name, Window),
        {error, #{code := wrong_target_kind}} = tmux_session:kill(Window),
        {ok, Pane} = tmux_pane:split(Window, #{direction => horizontal,
            size => {percent, 40}, launch => #{shell => <<>>}}),
        none = tmux_model:get(pid, Pane),
        WindowId = tmux_model:get(id, Window),
        WindowId = tmux_model:get(window_id, Pane),
        {ok, _} = tmux_window:kill(Window),
        {error, #{code := target_gone}} = tmux_window:rename(Window, <<"gone">>),
        {error, #{code := target_gone}} = tmux_pane:get(Server, tmux_model:get(id, Pane)),
        {ok, _} = tmux_session:kill(Session),
        {error, #{code := target_gone}} = tmux_session:get(Server, Id),
        ok = tmux_server:close(Server),
        {error, #{code := stale_reference}} = tmux_session:rename(Session, <<"stale">>)
    end).

launch_and_input(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        #{directory := Directory} = tmux_test_fixture:info(Fixture),
        Cwd = list_to_binary(filename:join(Directory, "cwd #{pane_id};\n%end")),
        ok = file:make_dir(Cwd),
        Ready = filename:join(Directory, "input-ready"),
        {ok, Listener} = gen_tcp:listen(0, [local, {ifaddr, {local, Ready}}, binary,
                                          {active, false}]),
        Script = <<"import os,socket,sys,json,tty,signal\n"
            "tty.setraw(0)\ns=socket.socket(socket.AF_UNIX)\ns.connect(sys.argv[1])\n"
            "p=json.dumps([sys.argv[2:],os.getcwd(),os.environ['LIBTMUX_VALUE']]).encode()\n"
            "s.sendall(len(p).to_bytes(4,'big')+p)\ndata=b''\n"
            "while len(data)<9:\n data+=os.read(0,9-len(data))\n"
            "s.sendall(data)\nsignal.pause()\n">>,
        Argument = <<"literal;\n#{pid}">>,
        Environment = <<"value;\n%end 1 2 3">>,
        try
            {ok, Session} = tmux_session:create(Server, #{name => <<"launch">>}),
            {ok, Window} = tmux_window:create(Session, #{launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, Pane} = tmux_pane:split(Window, #{cwd => Cwd,
                env => #{<<"LIBTMUX_VALUE">> => Environment},
                launch => #{argv => [<<"/usr/bin/python3">>, <<"-c">>, Script,
                                     list_to_binary(Ready), Argument]}}),
            {ok, Peer} = gen_tcp:accept(Listener, 900),
            try
                {ok, <<Length:32>>} = gen_tcp:recv(Peer, 4, 900),
                {ok, Payload} = gen_tcp:recv(Peer, Length, 900),
                [[Argument], Cwd, Environment] = json:decode(Payload),
                {ok, Current} = tmux_pane:get(Server, tmux_model:get(id, Pane)),
                Cwd = tmux_model:get(current_path, Current),
                {ok, Captured} = tmux_server:snapshot(Server),
                {ok, CapturedPane} = tmux_snapshot:get(pane, tmux_model:get(id, Pane), Captured),
                Cwd = tmux_model:get(current_path, CapturedPane),
                Input = <<0, 255, 27, 10, 13, $;, 16#c3, 16#a9>>,
                {ok, _} = tmux_pane:send_text(Pane, Input),
                {ok, _} = tmux_pane:send_keys(Pane, [enter]),
                Expected = <<Input/binary, 13>>,
                {ok, Expected} = gen_tcp:recv(Peer, 9, 900)
            after ok = gen_tcp:close(Peer)
            end,
            {ok, _} = tmux_session:kill(Session)
        after ok = gen_tcp:close(Listener)
        end
    end).

geometry(Config) ->
    with_server(Config, fun(Server, _) ->
        Launch = #{argv => [<<"/bin/cat">>]},
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"geometry">>, width => 120, height => 40, launch => Launch}),
        {ok, Window} = tmux_window:create(Session, #{launch => Launch}),
        {ok, Pane} = tmux_pane:split(Window,
            #{direction => horizontal, launch => Launch}),
        {ok, _} = tmux_window:select_layout(Window, even_horizontal),
        {ok, _} = tmux_pane:resize(Pane, #{width => 30}),
        PaneId = tmux_model:get(id, Pane),
        {ok, Resized} = tmux_pane:get(Server, PaneId),
        30 = tmux_model:get(width, Resized),
        {ok, _} = tmux_window:select_layout(Window, even_vertical),
        {ok, Vertical} = tmux_pane:get(Server, PaneId),
        120 = tmux_model:get(width, Vertical),
        true = tmux_model:get(height, Vertical) < 40,
        {ok, _} = tmux_pane:resize(Pane, #{height => 10}),
        {ok, HeightOnly} = tmux_pane:get(Server, PaneId),
        10 = tmux_model:get(height, HeightOnly),
        {ok, _} = tmux_pane:resize(Pane, #{width => 120, height => 12}),
        {ok, Both} = tmux_pane:get(Server, PaneId),
        120 = tmux_model:get(width, Both),
        12 = tmux_model:get(height, Both),
        30 = tmux_model:get(width, Resized),
        {ok, CurrentWindow} = tmux_window:get(Server, tmux_model:get(id, Window)),
        Layout = tmux_model:get(layout, CurrentWindow),
        {ok, _} = tmux_window:select_layout(Window, main_horizontal),
        {ok, _} = tmux_window:select_layout(Window, Layout),
        {ok, Restored} = tmux_pane:get(Server, PaneId),
        120 = tmux_model:get(width, Restored),
        12 = tmux_model:get(height, Restored),
        lists:foreach(fun(Bad) ->
            {error, #{code := invalid_layout}} = tmux_window:select_layout(Window, Bad)
        end, [<<"tiled; kill-server;">>, <<"not-a-layout">>, <<"a">>, <<"-n">>]),
        {error, #{code := command_error}} = tmux_window:select_layout(Window, <<"0000,x">>),
        {ok, Version} = tmux_server:version(Server),
        Json = <<"{\"V\":2,\"L\":{}}">>,
        case tmux_version:at_least(Version, {3, 8}) of
            false ->
                {error, #{code := unsupported_capability, capability := layout_json}} =
                    tmux_window:select_layout(Window, Json);
            true ->
                {error, #{code := command_error}} = tmux_window:select_layout(Window, Json)
        end,
        {ok, _} = tmux_session:kill(Session),
        {error, #{code := target_gone}} = tmux_pane:resize(Pane, #{width => 30})
    end).

membership_actions(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
        {ok, Work} = tmux_session:create(Server, Launch#{name => <<"work">>}),
        {ok, Mirror} = tmux_session:create(Server, Launch#{name => <<"mirror">>}),
        WorkId = tmux_model:get(id, Work),
        MirrorId = tmux_model:get(id, Mirror),
        {ok, Shared} = tmux_window:create(Work, Launch),
        SharedId = tmux_model:get(id, Shared),
        {ok, Source} = tmux_window_link:get(Server, WorkId, 1),
        SharedId = tmux_model:get(window_id, Source),
        {ok, Detached} = tmux_model:window_link(tmux_model:to_map(Source)),
        {error, #{code := detached_reference}} = tmux_window_link:select(Detached),
        {ok, Bound} = tmux_server:bind(Server, Detached),
        SharedId = tmux_model:get(window_id, Bound),
        {ok, _} = tmux_window_link:link(Source, Work, #{index => 7}),
        {ok, _} = tmux_window_link:link(Source, Mirror, #{index => 9}),
        {error, #{code := command_error}} =
            tmux_window_link:link(Source, Mirror, #{index => 9}),
        {ok, Copy} = tmux_window_link:get(Server, WorkId, 7),
        {ok, OriginalMirror} = tmux_window_link:get(Server, MirrorId, 0),
        OtherId = tmux_model:get(window_id, OriginalMirror),
        {ok, Mirrored} = tmux_window_link:get(Server, MirrorId, 9),
        {ok, _} = tmux_window_link:swap(Mirrored, OriginalMirror, #{}),
        {error, #{code := stale_link, expected := SharedId, actual := OtherId}} =
            tmux_window_link:unlink(Mirrored, #{force => true}),
        {error, #{code := stale_link, expected := SharedId, actual := OtherId}} =
            tmux_server:bind(Server, Mirrored),
        {ok, StillThere} = tmux_window_link:get(Server, MirrorId, 9),
        OtherId = tmux_model:get(window_id, StillThere),
        {ok, _} = tmux_window_link:move(Copy, Work, #{index => 11}),
        {error, #{code := target_gone}} = tmux_window_link:get(Server, WorkId, 7),
        {error, #{code := stale_link}} = tmux_window_link:select(Copy),
        {ok, Moved} = tmux_window_link:get(Server, WorkId, 11),
        SharedId = tmux_model:get(window_id, Moved),
        {ok, _} = tmux_window_link:unlink(Moved, #{}),
        {ok, Kept} = tmux_window_link:get(Server, WorkId, 1),
        SharedId = tmux_model:get(window_id, Kept),
        {ok, Selected} = tmux_window_link:get(Server, MirrorId, 0),
        {ok, _} = tmux_window_link:select(Selected),
        {ok, Active} = tmux_window_link:get(Server, MirrorId, 0),
        true = tmux_model:get(active, Active),
        {error, #{code := command_error}} = tmux_window_link:unlink(StillThere, #{}),
        {ok, _} = tmux_window_link:unlink(StillThere, #{force => true}),
        {error, #{code := target_gone}} = tmux_window:get(Server, OtherId),
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, SecondOwner} = tmux_server:open(#{socket_path => Socket,
            executable => proplists:get_value(executable, Config)}),
        try
            {ok, OtherOwnerSession} = tmux_session:get(SecondOwner, WorkId),
            {error, #{code := different_owner}} =
                tmux_window_link:link(Source, OtherOwnerSession, #{index => 13})
        after ok = tmux_server:close(SecondOwner)
        end,
        {ok, _} = tmux_session:kill(Mirror),
        {ok, _} = tmux_session:kill(Work)
    end).

capture_bytes(Config) ->
    with_server(Config, fun(Server, _) ->
        {ok, Session} = tmux_session:create(Server, #{name => <<"capture">>}),
        {ok, Window} = tmux_window:create(Session, #{launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Pane} = tmux_pane:split(Window, #{launch => #{shell => <<>>}}),
        {ok, Input} = tmux_command:raw(<<"display-message">>,
            [<<"-I">>, <<"-t">>, tmux_model:get(id, Pane)]),
        {ok, _} = tmux_server:command(Server, Input, #{stdin => <<"first\r\nsecond">>}),
        {ok, <<"first\nsecond\n">>} = tmux_pane:capture(Pane, #{start => 0, 'end' => 1}),
        {ok, _} = tmux_pane:kill(Pane),
        {error, #{code := target_gone}} = tmux_pane:capture(Pane, #{}),
        {ok, _} = tmux_session:kill(Session)
    end).

linked_snapshot(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"graph">>, window_name => <<"before">>, launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Other} = tmux_session:create(Server,
            #{name => <<"other">>, launch => #{argv => [<<"/bin/cat">>]}}),
        SessionId = tmux_model:get(id, Session),
        OtherId = tmux_model:get(id, Other),
        {ok, #{stdout := WindowOutput, exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"list-windows">>, <<"-t">>, SessionId, <<"-F">>, <<"#{window_id}">>]),
        WindowId = string:trim(WindowOutput, trailing, "\n"),
        {ok, Window} = tmux_window:get(Server, WindowId),
        {ok, Pane} = tmux_pane:split(Window, #{launch => #{shell => <<>>}}),
        lists:foreach(fun(Target) ->
            {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
                [<<"link-window">>, <<"-d">>, <<"-s">>, WindowId, <<"-t">>, Target])
        end, [<<SessionId/binary, ":7">>, <<SessionId/binary, ":11">>,
              <<OtherId/binary, ":4">>]),
        Title = <<"line one %end 1 2 3 #{pid}">>,
        {ok, LiteralTitle} = tmux_command:literal_format(Title),
        {ok, SetTitle} = tmux_command:raw(<<"select-pane">>,
            [<<"-t">>, tmux_model:get(id, Pane), <<"-T">>, LiteralTitle]),
        {ok, _} = tmux_server:command(Server, SetTitle, #{}),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        2 = length(tmux_snapshot:sessions(Snapshot)),
        2 = length(tmux_snapshot:windows(Snapshot)),
        3 = length(tmux_snapshot:panes(Snapshot)),
        5 = length(tmux_snapshot:window_links(Snapshot)),
        {ok, CapturedSession} = tmux_snapshot:get(session, SessionId, Snapshot),
        {ok, CapturedWindow} = tmux_snapshot:get(window, WindowId, Snapshot),
        {ok, [CapturedWindow]} = tmux_snapshot:related(windows, CapturedSession, Snapshot),
        {ok, Memberships} = tmux_snapshot:related(window_links, CapturedSession, Snapshot),
        [0, 7, 11] = [tmux_model:get(index, L) || L <- Memberships],
        {ok, Children} = tmux_snapshot:related(panes, CapturedWindow, Snapshot),
        [0, 1] = [tmux_model:get(index, P) || P <- Children],
        {ok, CapturedPane} = tmux_snapshot:get(pane, tmux_model:get(id, Pane), Snapshot),
        Title = tmux_model:get(title, CapturedPane),
        #{id := SnapshotId, generation := Generation, capture_started := Start,
          capture_finished := Finish, source_calls := Calls, observed_bytes := Bytes} =
            tmux_snapshot:metadata(Snapshot),
        true = is_reference(Generation),
        true = Start =< Finish,
        true = length(Calls) > 6,
        Bytes = lists:sum([maps:get(stdout_bytes, Call) || Call <- Calls]),
        true = lists:all(fun(#{started := A, finished := B}) ->
            Start =< A andalso A =< B andalso B =< Finish
        end, Calls),
        SnapshotId = tmux_model:snapshot_id(CapturedPane),
        ok = tmux_snapshot:require([{relation, session, windows}, {field, pane, title}], Snapshot),
        {ok, _} = tmux_window:rename(Window, <<"after">>),
        <<"before">> = tmux_model:get(name, CapturedWindow),
        {ok, NewSnapshot} = tmux_server:snapshot(Server),
        {ok, NewWindow} = tmux_snapshot:get(window, WindowId, NewSnapshot),
        <<"after">> = tmux_model:get(name, NewWindow),
        {error, #{code := snapshot_row_mismatch}} =
            tmux_snapshot:related(panes, CapturedWindow, NewSnapshot),
        ok = tmux_server:close(Server),
        {ok, Children} = tmux_snapshot:related(panes, CapturedWindow, Snapshot),
        %% Count real calls in an isolated trace session. Local filtering must
        %% remain independent of the now-closed owner and stop on match two.
        Trace = trace:session_create(local_query, self(), []),
        Boundaries = [{tmux_transport, run, 3}, {tmux_operation, start, 3},
                      {tmux_server, command, 3}, {tmux_observe, snapshot, 2},
                      {tmux_observe, get, 3}],
        try
            lists:foreach(fun(MFA) -> 1 = trace:function(Trace, MFA, true, [call_count]) end, Boundaries),
            Selection = tmux_select:panes(Snapshot),
            Criteria = #{title => Title, pid => #{present => false},
                         window => #{is => #{name => <<"before">>}}},
            {ok, CapturedPane} = tmux_select:one(Criteria, Selection),
            1 = tmux_select:count(#{panes => #{count => #{gte => 2}}}, tmux_select:windows(Snapshot)),
            1 = tmux_select:count(#{window_links => #{count => 3}}, tmux_select:sessions(Snapshot)),
            1 = trace:function(Trace, {tmux_filter_eval, matches, 2}, true, [call_count]),
            {error, {multiple_matches, #{at_least := 2}}} = tmux_select:one(#{}, Selection),
            {call_count, 2} = trace:info(Trace, {tmux_filter_eval, matches, 2}, call_count),
            lists:foreach(fun(MFA) -> {call_count, 0} = trace:info(Trace, MFA, call_count) end, Boundaries)
        after true = trace:session_destroy(Trace)
        end,
        {error, #{code := stale_reference}} = tmux_window:rename(CapturedWindow, <<"closed">>)
    end).

snapshot_limits(Config) ->
    with_server(Config, fun(Server, Fixture) ->
        {ok, Empty} = tmux_server:snapshot(Server),
        [] = tmux_snapshot:panes(Empty),
        ok = tmux_snapshot:require([{relation, session, windows}, {field, pane, title}], Empty),
        {ok, _} = tmux_session:create(Server, #{name => <<"limits">>, launch => #{argv => [<<"/bin/cat">>]}}),
        {error, #{code := capture_limit, limit := max_rows}} =
            tmux_server:snapshot(Server, #{max_rows => 1}),
        {error, #{code := output_limit, stream := stdout}} =
            tmux_server:snapshot(Server, #{max_bytes => 1}),
        {error, #{code := unsupported_consistency}} =
            tmux_server:snapshot(Server, #{consistency => atomic}),
        {error, #{code := invalid_capture_options}} =
            tmux_server:snapshot(Server, #{max_rows => 0}),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        [_] = tmux_snapshot:sessions(Snapshot),
        %% A real after-hook changes membership after the first pane scan.
        Hook = <<"set-hook -gu after-list-panes ; "
                 "new-window -d -t limits: -n added /bin/cat">>,
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"set-hook">>, <<"-g">>, <<"after-list-panes">>, Hook]),
        {error, #{code := inconsistent_capture, reason := topology_changed}} =
            tmux_server:snapshot(Server),
        {ok, Repeated} = tmux_server:snapshot(Server),
        2 = length(tmux_snapshot:windows(Repeated))
    end).

with_server(Config, Fun) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, Server} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try Fun(Server, Fixture)
        after ok = tmux_server:close(Server)
        end
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end.
