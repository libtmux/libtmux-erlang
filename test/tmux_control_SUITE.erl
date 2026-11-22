-module(tmux_control_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, attachment/1,
         parent_closing/1, caller_death/1, attachment_hook/1, cleanup_pending/1,
         expired_startup/1, endpoint_unavailable/1, malformed_identity_tail/1,
         submitted_read_group/1, cancelled_mutation_group/1,
         submitted_mutation_group/1, mutation_hook_gap/1, overridden_marker/1]).

%% Outer: real control clients and owned process retirement on both branches.
all() -> [attachment, parent_closing, caller_death, attachment_hook, cleanup_pending,
          expired_startup, endpoint_unavailable, malformed_identity_tail,
          submitted_read_group, cancelled_mutation_group, submitted_mutation_group,
          mutation_hook_gap, overridden_marker].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    [{executable, unicode:characters_to_binary(Executable)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

submitted_read_group(Config) ->
    with_owned_control(Config, fun(Server, Session, Control) ->
        Id = tmux_model:get(id, Session),
        First = <<Id/binary, 10>>,
        Sessions = sessions_read(),
        {ok, Windows} = tmux_command:raw(<<"list-windows">>,
            [<<"-t">>, Id, <<"-F">>, <<"#{window_id}">>]),
        {ok, Panes} = tmux_command:raw(<<"list-panes">>,
            [<<"-t">>, Id, <<"-F">>, <<"#{pane_id}">>]),
        {ok, #{stdout := WindowIds}} = tmux_server:command(Server, Windows, #{}),
        {ok, #{stdout := PaneIds}} = tmux_server:command(Server, Panes, #{}),
        {error, #{code := control_group_limit}} =
            tmux_control:submit(Control, lists:duplicate(17, Sessions), #{}),
        {ok, Success} = tmux_control:submit(Control, [Sessions, Windows, Panes], #{}),
        {ok, #{replies := [First, WindowIds, PaneIds]}} = tmux_control:await(Success, 900),

        {ok, Missing} = tmux_command:raw(<<"list-panes">>,
            [<<"-t">>, <<"$4294967294">>, <<"-F">>, <<"#{pane_id}">>]),
        {ok, Failed} = tmux_control:submit(Control, [Sessions, Missing, Panes], #{}),
        {error, #{code := command_error, index := 2, replies := [First]}} =
            tmux_control:await(Failed, 900),

        {ok, Read} = tmux_control:submit(Control, Sessions, #{}),
        {ok, #{replies := [First]}} = tmux_control:await(Read, 900),
        {error, #{code := control_submission_expired}} = tmux_control:await(Success, 900),
        {ok, Unsupported} = tmux_command:raw(<<"display-message">>,
            [<<"-p">>, <<"read">>]),
        {error, #{code := unsupported_control_command}} =
            tmux_control:submit(Control, Unsupported, #{}),
        ok
    end).

cancelled_mutation_group(Config) ->
    with_owned_control(Config, fun(Server, Session, Control = {control, Owner, _}) ->
        {ok, #{helper_pid := Helper}} = tmux_control:status(Control),
        Identity = tmux_test_fixture:process_identity(Helper),
        Id = tmux_model:get(id, Session),
        {ok, Rename} = tmux_session:rename_command(Session, <<"pending">>),
        try
            signal_helper(Helper, Identity, <<"-STOP">>),
            {ok, Pending} = tmux_control:submit(Control, Rename, #{}),
            {error, #{code := await_timeout}} = tmux_control:await(Pending, 0),
            {error, #{code := busy}} = tmux_control:submit(Control, sessions_read(), #{}),
            {ok, Current} = tmux_session:get(Server, Id),
            <<"reads">> = tmux_model:get(name, Current),
            ok = tmux_control:cancel(Pending),
            {ok, #{phase := closing, cleanup := pending}} = tmux_control:status(Control),
            #{close_timer := Timer} = sys:get_state(Owner),
            Owner ! {timeout, Timer, cleanup},
            {error, #{code := cancelled, outcome := unknown, replies := [],
                      cleanup := incomplete}} = tmux_control:await(Pending, 900),
            Retired = tmux_control:send_request(Control, retired),
            signal_helper(Helper, Identity, <<"-CONT">>),
            {reply, ok} = gen_server:receive_response(Retired, 900),
            {error, #{code := cancelled, outcome := unknown, cleanup := complete}} =
                tmux_control:await(Pending, 900),
            false = tmux_test_fixture:same_process(Helper, Identity),
            ok
        after
            case tmux_test_fixture:same_process(Helper, Identity) of
                true -> signal_helper(Helper, Identity, <<"-CONT">>);
                false -> ok
            end
        end
    end).

sessions_read() ->
    {ok, Command} = tmux_command:raw(<<"list-sessions">>, [<<"-F">>, <<"#{session_id}">>]),
    Command.

submitted_mutation_group(Config) ->
    with_owned_control(Config, fun(Server, Session, Control) ->
        {ok, Snapshot} = tmux_server:snapshot(Server),
        [Window] = tmux_snapshot:windows(Snapshot),
        [Pane] = tmux_snapshot:panes(Snapshot),
        {ok, _} = tmux_pane:split(Pane, #{direction => horizontal,
            launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Vertical} = tmux_pane:split(Pane, #{direction => vertical,
            launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Alias} = tmux_command:raw(<<"set-option">>,
            [<<"-s">>, <<"command-alias[100]">>, <<"read-label=list-sessions">>]),
        {ok, _} = tmux_server:command(Server, Alias, #{}),
        {ok, Rename} = tmux_session:rename_command(Session, <<"working; still literal">>),
        {ok, ResizeWindow} = tmux_window:resize_command(Window, #{width => 110, height => 31}),
        {ok, ResizePane} = tmux_pane:resize_command(Pane, #{width => 31, height => 11}),
        {ok, Group} = tmux_command:sequence([Rename, ResizeWindow, ResizePane, sessions_read()]),
        {ok, Work} = tmux_control:submit(Control, Group, #{}),
        Id = tmux_model:get(id, Session),
        IdLine = <<Id/binary, 10>>,
        {ok, #{replies := [<<>>, <<>>, <<>>, IdLine]}} =
            tmux_control:await(Work, 900),
        {ok, Fresh} = tmux_server:snapshot(Server),
        [CurrentWindow] = tmux_snapshot:windows(Fresh),
        110 = tmux_model:get(width, CurrentWindow),
        31 = tmux_model:get(height, CurrentWindow),
        {ok, CurrentPane} = tmux_pane:get(Server, tmux_model:get(id, Pane)),
        31 = tmux_model:get(width, CurrentPane),
        11 = tmux_model:get(height, CurrentPane),
        {ok, ReadAlias} = tmux_command:raw(<<"read-label">>, [<<"-F">>, <<"#{session_name}">>]),
        {ok, #{stdout := <<"working; still literal\n">>}} =
            tmux_server:command(Server, ReadAlias, #{}),
        reject_foreign_command(Config, Server, Id, Control),

        assert_missing_targets(Server, Session, Vertical, Control),
        {ok, Again} = tmux_control:submit(Control, sessions_read(), #{}),
        {ok, #{replies := [IdLine]}} = tmux_control:await(Again, 900),
        ok
    end).

assert_missing_targets(Server, Session, Vertical, Control) ->
    Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
    {ok, GoneSession} = tmux_session:create(Server, Launch#{name => <<"gone">>}),
    {ok, Rename} = tmux_session:rename_command(GoneSession, <<"absent">>),
    {ok, _} = tmux_session:kill(GoneSession),
    {ok, GoneWindow} = tmux_window:create(Session, Launch),
    {ok, ResizeWindow} = tmux_window:resize_command(GoneWindow, #{width => 90}),
    {ok, _} = tmux_window:kill(GoneWindow),
    {ok, ResizePane} = tmux_pane:resize_command(Vertical, #{height => 9}),
    {ok, _} = tmux_pane:kill(Vertical),
    {ok, Prefix} = tmux_session:rename_command(Session, <<"prefix">>),
    {ok, Tail} = tmux_session:rename_command(Session, <<"skipped">>),
    lists:foreach(fun(Missing) ->
        {ok, Work} = tmux_control:submit(Control, [Prefix, Missing, Tail], #{}),
        {error, #{code := command_error, index := 2, replies := [<<>>]}} =
            tmux_control:await(Work, 900),
        {ok, Current} = tmux_session:get(Server, tmux_model:get(id, Session)),
        <<"prefix">> = tmux_model:get(name, Current)
    end, [Rename, ResizeWindow, ResizePane]).

reject_foreign_command(Config, Server, Id, Control) ->
    {ok, #{endpoint := #{socket_path := Socket}}} = tmux_server:observation_context(Server),
    Executable = proplists:get_value(executable, Config),
    {ok, Other} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
    try
        {ok, Foreign} = tmux_session:get(Other, Id),
        {ok, Rename} = tmux_session:rename_command(Foreign, <<"another endpoint">>),
        {error, #{code := different_owner, outcome := not_started}} =
            tmux_control:submit(Control, Rename, #{}),
        {ok, Unchanged} = tmux_session:get(Server, Id),
        <<"working; still literal">> = tmux_model:get(name, Unchanged),
        ok
    after ok = tmux_server:close(Other)
    end.

mutation_hook_gap(Config) ->
    with_owned_control(Config, fun(Server, Session, Control) ->
        {ok, Hook} = tmux_command:raw(<<"set-hook">>,
            [<<"-g">>, <<"after-rename-session">>, <<"display-message -p hook-visible">>]),
        {ok, _} = tmux_server:command(Server, Hook, #{}),
        {ok, Rename} = tmux_session:rename_command(Session, <<"applied">>),
        {ok, Work} = tmux_control:submit(Control, Rename, #{}),
        {error, #{code := unexpected_control_block, outcome := unknown,
                  replies := [<<>>], cleanup := complete}} = tmux_control:await(Work, 900),
        {ok, Fresh} = tmux_session:get(Server, tmux_model:get(id, Session)),
        <<"applied">> = tmux_model:get(name, Fresh),
        ok
    end).

overridden_marker(Config) ->
    with_owned_control(Config, fun(Server, Session, Control) ->
        Alias = <<"display-message=list-sessions">>,
        {ok, SetAlias} = tmux_command:raw(<<"set-option">>,
            [<<"-s">>, <<"command-alias[100]">>, Alias]),
        {ok, _} = tmux_server:command(Server, SetAlias, #{}),
        {ok, Rename} = tmux_session:rename_command(Session, <<"renamed">>),
        {ok, Work} = tmux_control:submit(Control, Rename, #{}),
        {error, #{code := unexpected_control_reply, outcome := unknown,
                  replies := [<<>>], cleanup := complete}} = tmux_control:await(Work, 900),
        {ok, GetAlias} = tmux_command:raw(<<"show-options">>,
            [<<"-sv">>, <<"command-alias[100]">>]),
        {ok, #{stdout := <<Alias:(byte_size(Alias))/binary, 10>>}} =
            tmux_server:command(Server, GetAlias, #{}),
        ok
    end).

with_owned_control(Config, Function) ->
    Executable = proplists:get_value(executable, Config),
    {ok, ok} = tmux_server:with_owned(#{executable => Executable}, fun(Server) ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"reads">>, launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Control} = tmux_control:attach(Server, Session, #{}),
        try Function(Server, Session, Control)
        after ok = tmux_control:close(Control)
        end
    end),
    ok.

attachment(Config) ->
    with_session(Config, fun(Server, Session, Fixture) ->
        Id = tmux_model:get(id, Session),
        {ok, _} = tmux_test_fixture:command(Fixture,
            [<<"set-option">>, <<"-t">>, <<Id/binary, ":">>, <<"update-environment">>, <<"PATH">>]),
        {ok, _} = tmux_test_fixture:command(Fixture,
            [<<"set-environment">>, <<"-t">>, Id, <<"PATH">>, <<"/preserved-session-path">>]),
        {ok, Control} = tmux_control:attach(Server, Session, #{}),
        try
            {error, #{code := control_requires_owned_server}} =
                tmux_control:submit(Control, sessions_read(), #{}),
            {ok, #{phase := open, identity := same_connection,
                   child_pid := Child, helper_pid := Helper}} = tmux_control:status(Control),
            ChildIdentity = tmux_test_fixture:process_identity(Child),
            HelperIdentity = tmux_test_fixture:process_identity(Helper),
            {ok, Attached} = tmux_session:get(Server, Id),
            1 = tmux_model:get(attached_count, Attached),
            {ok, #{stdout := <<"PATH=/preserved-session-path\n">>}} =
                tmux_test_fixture:command(Fixture,
                    [<<"show-environment">>, <<"-t">>, Id, <<"PATH">>]),
            ok = tmux_control:close(Control),
            {ok, #{phase := closed, cleanup := complete}} = tmux_control:status(Control),
            false = tmux_test_fixture:same_process(Child, ChildIdentity),
            false = tmux_test_fixture:same_process(Helper, HelperIdentity),
            ok = tmux_control:close(Control),
            {ok, Detached} = tmux_session:get(Server, Id),
            0 = tmux_model:get(attached_count, Detached),
            #{socket := Socket} = tmux_test_fixture:info(Fixture),
            {ok, Other} = tmux_server:open(#{socket_path => Socket,
                executable => proplists:get_value(executable, Config)}),
            try
                {error, #{code := different_owner}} = tmux_control:attach(Other, Session, #{})
            after ok = tmux_server:close(Other)
            end,
            {ok, _} = tmux_session:kill(Session),
            {error, #{code := control_attach_error, cleanup := complete}} =
                tmux_control:attach(Server, Session, #{}),
            {ok, #{owner := Endpoint}} = tmux_server:status(Server),
            #{closing_watchers := Watchers} = sys:get_state(Endpoint),
            0 = map_size(Watchers),
            {ok, #{stdout := <<>>}} = tmux_test_fixture:command(Fixture,
                [<<"list-sessions">>, <<"-F">>, <<"#{session_id}">>])
        after ok = tmux_control:close(Control)
        end
    end).

parent_closing(Config) ->
    with_session(Config, fun(Server, Session, _) ->
        {ok, Control} = tmux_control:attach(Server, Session, #{}),
        try
            Retired = tmux_control:send_request(Control, retired),
            ok = tmux_server:close(Server),
            {reply, ok} = gen_server:receive_response(Retired, 900),
            {ok, #{phase := closed, cleanup := complete}} = tmux_control:status(Control)
        after ok = tmux_control:close(Control)
        end
    end).

caller_death(Config) ->
    with_session(Config, fun(Server, Session, _) ->
        Parent = self(),
        {Caller, Monitor} = spawn_monitor(fun() ->
            {ok, Control} = tmux_control:attach(Server, Session, #{}),
            Parent ! {attached, self(), Control},
            receive finish -> ok end
        end),
        try
            Control = receive {attached, Caller, Handle} -> Handle
                      after 900 -> ct:fail(attachment_not_ready)
                      end,
            Retired = tmux_control:send_request(Control, retired),
            exit(Caller, kill),
            receive {'DOWN', Monitor, process, Caller, killed} -> ok
            after 900 -> ct:fail(caller_alive)
            end,
            {reply, ok} = gen_server:receive_response(Retired, 900),
            {ok, #{phase := closed, cleanup := complete}} = tmux_control:status(Control),
            ok = tmux_control:close(Control)
        after exit(Caller, kill)
        end
    end).

attachment_hook(Config) ->
    with_session(Config, fun(Server, Session, Fixture) ->
        Id = tmux_model:get(id, Session),
        lists:foreach(fun({Output, Code}) ->
            {ok, Literal} = tmux_command:literal_format(Output, time),
            {ok, _} = tmux_test_fixture:command(Fixture,
                [<<"set-hook">>, <<"-t">>, <<Id/binary, ":">>, <<"client-attached">>,
                 <<"display-message -p '", Literal/binary, "'">>]),
            %% This hook writes unframed output on both supported branches.
            {error, #{code := Code, cleanup := complete}} =
                tmux_control:attach(Server, Session, #{})
        end, [{<<"HOOK-OUTPUT">>, invalid_control_line},
              {<<"%begin 1 2 0">>, unexpected_control_block}]),
        {ok, Detached} = tmux_session:get(Server, Id),
        0 = tmux_model:get(attached_count, Detached)
    end).

cleanup_pending(Config) ->
    with_session(Config, fun(Server, Session, _) ->
        {ok, Control = {control, Owner, _}} = tmux_control:attach(Server, Session, #{}),
        {ok, #{helper_pid := Helper}} = tmux_control:status(Control),
        Identity = tmux_test_fixture:process_identity(Helper),
        try
            signal_helper(Helper, Identity, <<"-STOP">>),
            Retired = tmux_control:send_request(Control, retired),
            Closing = gen_server:send_request(Owner,
                {element(3, Control), close, make_ref()}),
            {ok, #{phase := closing, cleanup := pending}} = tmux_control:status(Control),
            #{close_timer := Timer} = sys:get_state(Owner),
            Owner ! {timeout, Timer, cleanup},
            {reply, {error, #{code := cleanup_incomplete}}} =
                gen_server:receive_response(Closing, 900),
            timeout = gen_server:wait_response(Retired, 0),
            {ok, #{phase := closing, cleanup := incomplete}} = tmux_control:status(Control),
            signal_helper(Helper, Identity, <<"-CONT">>),
            {reply, ok} = gen_server:receive_response(Retired, 900),
            false = tmux_test_fixture:same_process(Helper, Identity),
            ok = tmux_control:close(Control)
        after
            case tmux_test_fixture:same_process(Helper, Identity) of
                true -> signal_helper(Helper, Identity, <<"-CONT">>);
                false -> ok
            end,
            ok = tmux_control:close(Control)
        end
    end).

signal_helper(Pid, Identity, Signal) ->
    true = tmux_test_fixture:same_process(Pid, Identity),
    {ok, #{exit_status := 0, cleanup := complete}} = tmux_transport:run(
        <<"/bin/kill">>, [Signal, integer_to_binary(Pid)], #{}),
    ok.

expired_startup(Config) ->
    with_session(Config, fun(Server, Session, _) ->
        lists:foreach(fun(Boundary) ->
            {ok, Control = {control, Owner, Generation}} = tmux_control:attach(Server, Session, #{}),
            try
                #{channel := Channel = {transport, ChannelOwner, _, _}} = sys:get_state(Owner),
                #{write_id := Writes} = sys:get_state(ChannelOwner),
                _ = sys:replace_state(Owner, fun(State) ->
                    Settings = maps:get(config, State),
                    Base = State#{phase => attaching, timer => none,
                        config => Settings#{deadline => erlang:monotonic_time(millisecond) - 1}},
                    case Boundary of
                        before_probe -> Base#{startup => attachment, block => none,
                            codec => tmux_control_codec:new(Generation)};
                        before_ready -> Base#{startup => verified, write => {0, 1}}
                    end
                end),
                Retired = tmux_control:send_request(Control, retired),
                case Boundary of
                    before_probe ->
                        Owner ! {tmux_transport, Channel, {data, stdout, 1,
                            <<"%begin 1 2 0\n%end 1 2 0\n">>}};
                    before_ready -> Owner ! {tmux_transport, Channel, {write_ack, 0, 1}}
                end,
                {ok, #{cause := startup_timeout}} = tmux_control:status(Control),
                {reply, ok} = gen_server:receive_response(Retired, 900),
                #{write_id := Writes} = sys:get_state(ChannelOwner)
            after ok = tmux_control:close(Control)
            end
        end, [before_probe, before_ready])
    end).

endpoint_unavailable(Config) ->
    {Server, Session} = with_session(Config, fun(Endpoint, Captured, _) ->
        {Endpoint, Captured}
    end),
    ok = application:stop(libtmux_erlang),
    try
        {error, #{code := control_unavailable, cleanup := complete}} =
            tmux_control:attach(Server, Session, #{})
    after {ok, _} = application:ensure_all_started(libtmux_erlang)
    end.

malformed_identity_tail(Config) ->
    with_session(Config, fun(Server, Session, _) ->
        lists:foreach(fun(Boundary) ->
            {ok, Control = {control, Owner, Generation}} = tmux_control:attach(Server, Session, #{}),
            try
                #{channel := Channel = {transport, ChannelOwner, _, _},
                  context := #{config := Native}} = sys:get_state(Owner),
                #{write_id := Writes} = sys:get_state(ChannelOwner),
                Nonce = <<"prefix-test">>,
                _ = sys:replace_state(Owner, fun(State) ->
                    State#{phase => attaching, startup => Boundary, probe => Nonce,
                        identity => unverified, codec => tmux_control_codec:new(Generation)}
                end),
                Ready = gen_server:send_request(Owner, {Generation, ready, make_ref()}),
                Frame = case Boundary of
                    attachment -> <<"%begin 1 2 0\n%end 1 2 0\nINVALID\n">>;
                    probe ->
                        Pid = integer_to_binary(maps:get(server_pid, Native)),
                        #{raw := <<"tmux ", RawVersion/binary>>} = maps:get(version, Native),
                        Version = string:trim(RawVersion),
                        <<"%begin 1 2 1\n", Nonce/binary, $:, Pid/binary, $:,
                          Version/binary, "\n%end 1 2 1\nINVALID\n">>
                end,
                Owner ! {tmux_transport, Channel, {data, stdout, 1, Frame}},
                {reply, {error, #{code := invalid_control_line, cleanup := complete}}} =
                    gen_server:receive_response(Ready, 900),
                #{write_id := Writes} = sys:get_state(ChannelOwner)
            after ok = tmux_control:close(Control)
            end
        end, [probe, attachment])
    end).

with_session(Config, Function) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try
        #{socket := Socket} = tmux_test_fixture:info(Fixture),
        {ok, Server} = tmux_server:open(#{socket_path => Socket, executable => Executable}),
        try
            {ok, Session} = tmux_session:create(Server,
                #{name => <<"control">>, launch => #{argv => [<<"/bin/cat">>]}}),
            Function(Server, Session, Fixture)
        after ok = tmux_server:close(Server)
        end
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end.
