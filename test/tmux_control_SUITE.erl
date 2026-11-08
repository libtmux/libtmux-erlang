-module(tmux_control_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, attachment/1,
         parent_closing/1, caller_death/1, attachment_hook/1, cleanup_pending/1,
         expired_startup/1, endpoint_unavailable/1, malformed_identity_tail/1]).

%% Outer: real control clients and owned process retirement on both branches.
all() -> [attachment, parent_closing, caller_death, attachment_hook, cleanup_pending,
          expired_startup, endpoint_unavailable, malformed_identity_tail].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    [{executable, unicode:characters_to_binary(Executable)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

attachment(Config) ->
    with_session(Config, fun(Server, Session, Fixture) ->
        Id = tmux_model:get(id, Session),
        {ok, _} = tmux_test_fixture:command(Fixture,
            [<<"set-option">>, <<"-t">>, <<Id/binary, ":">>, <<"update-environment">>, <<"PATH">>]),
        {ok, _} = tmux_test_fixture:command(Fixture,
            [<<"set-environment">>, <<"-t">>, Id, <<"PATH">>, <<"/preserved-session-path">>]),
        {ok, Control} = tmux_control:attach(Server, Session, #{}),
        try
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
