-module(tmux_command_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, literal_arguments/1,
         singleton_argv/1, source_configuration/1, wait_channels/1]).

%% Outer: tmux argv/format parsing and singleton pane-command execution.
all() -> [literal_arguments, singleton_argv, source_configuration, wait_channels].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Binary = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    true = is_list(Binary),
    [{tmux, list_to_binary(Binary)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

literal_arguments(Config) ->
    {ok, Fixture} = tmux_test_fixture:start(proplists:get_value(tmux, Config)),
    try
        lists:foreach(fun(Value) ->
            {ok, Literal} = tmux_command:literal_format(Value, time),
            {ok, Command} = tmux_command:raw(<<"display-message">>, [<<"-p">>, Literal]),
            {ok, #{stdout := Output, exit_status := 0}} =
                tmux_test_fixture:command(Fixture, tmux_command:argv(Command)),
            Expected = <<Value/binary, 10>>,
            Expected = Output
        end, [<<"literal;">>, <<"slash\\;">>, <<";">>,
              <<"api-#{pane_id},};">>, <<"literal\n%end 1 2 3">>])
    after ok = tmux_test_fixture:close(Fixture)
    end.

singleton_argv(Config) ->
    {ok, Fixture} = tmux_test_fixture:start(proplists:get_value(tmux, Config)),
    try
        #{directory := Directory} = tmux_test_fixture:info(Fixture),
        Executable = filename:join(Directory, "a program; with spaces"),
        Ready = filename:join(Directory, "program-ready"),
        {ok, Listener} = gen_tcp:listen(0, [local, {ifaddr, {local, Ready}}, binary,
                                          {active, false}]),
        %% A kernel shebang is explicit executable behavior; tmux must not parse its name.
        ok = file:write_file(Executable, ["#!/usr/bin/python3\nimport socket, signal\n",
            io_lib:format("s=socket.socket(socket.AF_UNIX)\ns.connect(~p)\n", [Ready]),
            "s.sendall(b'R')\ns.close()\nsignal.pause()\n"]),
        ok = file:change_mode(Executable, 8#700),
        {ok, Launch} = tmux_command:launch(#{argv => [list_to_binary(Executable)]}),
        {ok, Command} = tmux_command:raw(<<"new-session">>,
            [<<"-d">>, <<"-s">>, <<"literal">> | Launch]),
        {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture, tmux_command:argv(Command)),
        try
            {ok, Peer} = gen_tcp:accept(Listener, 900),
            try {ok, <<"R">>} = gen_tcp:recv(Peer, 1, 900)
            after ok = gen_tcp:close(Peer)
            end
        after ok = gen_tcp:close(Listener)
        end
    after ok = tmux_test_fixture:close(Fixture)
    end.

source_configuration(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(tmux, Config), fun(Server, Fixture) ->
        #{directory := Directory} = tmux_test_fixture:info(Fixture),
        Path = list_to_binary(filename:join(Directory, "config*[ab]?\\#{pid};")),
        Decoy = list_to_binary(filename:join(Directory, "configZabQ#{pid};")),
        ok = file:write_file(Path, <<"set-option -g @literal_source yes\n">>),
        ok = file:write_file(Decoy, <<"set-option -g @decoy_source no\n">>),
        {ok, Source} = tmux_command:source_file(Path, #{}),
        {ok, _} = tmux_server:command(Server, Source, #{}),
        {ok, <<"yes">>} = tmux_option:get({session_defaults, Server}, <<"@literal_source">>, #{}),
        none = tmux_option:get({session_defaults, Server}, <<"@decoy_source">>, #{}),
        Text = <<"set-option -g @literal_source changed\n">>,
        {ok, Parse} = tmux_command:source_file(stdin, #{parse_only => true}),
        {ok, _} = tmux_server:command(Server, Parse, #{stdin => Text}),
        {ok, <<"yes">>} = tmux_option:get({session_defaults, Server}, <<"@literal_source">>, #{}),
        {ok, Stdin} = tmux_command:source_file(stdin, #{}),
        {ok, _} = tmux_server:command(Server, Stdin, #{stdin => Text}),
        {ok, <<"changed">>} = tmux_option:get({session_defaults, Server}, <<"@literal_source">>, #{}),
        {error, #{code := command_error, cleanup := complete}} =
            tmux_server:command(Server, Stdin, #{stdin => <<"no-such-command\n">>}),
        Missing = <<Path/binary, "-missing">>,
        {ok, Absent} = tmux_command:source_file(Missing, #{}),
        {error, #{code := command_error}} = tmux_server:command(Server, Absent, #{}),
        {ok, Quiet} = tmux_command:source_file(Missing, #{quiet => true}),
        {ok, _} = tmux_server:command(Server, Quiet, #{}),
        {ok, Healthy} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"still alive">>]),
        {ok, #{stdout := <<"still alive\n">>}} = tmux_server:command(Server, Healthy, #{})
    end).

wait_channels(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(tmux, Config), fun(Server, Fixture) ->
        Channel = <<"channel #{pid};">>,
        {ok, Signal} = tmux_command:wait_for(Channel, signal),
        {ok, Wait} = tmux_command:wait_for(Channel, wait),
        {ok, _} = tmux_server:command(Server, Signal, #{}),
        {ok, _} = tmux_server:command(Server, Wait, #{}),
        {ok, Op} = tmux_operation:start(Server, Wait, #{}),
        {ok, _} = tmux_operation:await_started(Op, 900),
        {ok, _} = tmux_server:command(Server, Signal, #{}),
        {ok, #{cleanup := complete}} = tmux_operation:await(Op, 900),
        {ok, Lock} = tmux_command:wait_for(Channel, lock),
        {ok, Unlock} = tmux_command:wait_for(Channel, unlock),
        {ok, #{cleanup := complete}} = tmux_server:command(Server, Lock, #{}),
        {ok, _} = tmux_server:command(Server, Unlock, #{}),
        {error, #{code := command_error}} = tmux_server:command(Server, Unlock, #{}),
        duplicate_signal_clears_pending(Server, Fixture)
    end).

duplicate_signal_clears_pending(Server, Fixture) ->
    {ok, First} = tmux_session:create(Server, #{launch => #{argv => [<<"/bin/cat">>]}}),
    {ok, Second} = tmux_session:create(Server, #{launch => #{argv => [<<"/bin/cat">>]}}),
    Id0 = tmux_model:get(id, First),
    Id1 = tmux_model:get(id, Second),
    {ok, Signal} = tmux_command:wait_for(<<"duplicate-signal">>, signal),
    {ok, _} = tmux_server:command(Server, Signal, #{}),
    {ok, _} = tmux_server:command(Server, Signal, #{}),
    tmux_test_fixture:with_client(Fixture, Id0, [], fun(Client) ->
        #{port := Port, name := Name} = Client,
        true = erlang:port_command(Port,
            <<"wait-for duplicate-signal ; ",
              "display-message -p wait-resumed-marker\n">>),
        Deadline = erlang:monotonic_time(millisecond) + 900,
        Number = wait_begin(Port, Deadline, 65536),
        {ok, _} = tmux_session:select(Second, Name),
        %% %end is emitted even for a waiting command. A following command's
        %% marker proves queue progress; compare its order with an independent
        %% event in the same stream instead of asserting timed absence.
        change_before_marker(Port, Id1, Number, Deadline, 65536),
        {ok, _} = tmux_server:command(Server, Signal, #{}),
        wait_marker(Port, erlang:monotonic_time(millisecond) + 900, 65536),
        {Name, Id1} = tmux_test_fixture:client_session(Client)
    end).

wait_begin(Port, Deadline, Budget) ->
    {Line, Left} = control_line(Port, Deadline, Budget),
    case binary:split(Line, <<" ">>, [global]) of
        [<<"%begin">>, _, Number, _] -> Number;
        _ -> wait_begin(Port, Deadline, Left)
    end.

change_before_marker(Port, Session, Number, Deadline, Budget) ->
    {Line, Left} = control_line(Port, Deadline, Budget),
    case binary:split(Line, <<" ">>, [global]) of
        [<<"wait-resumed-marker">>] -> error(duplicate_signal_was_retained);
        [<<"%error">>, _, Number, _] -> error(wait_command_failed);
        [<<"%session-changed">>, Session | _] -> ok;
        _ -> change_before_marker(Port, Session, Number, Deadline, Left)
    end.

wait_marker(Port, Deadline, Budget) ->
    case control_line(Port, Deadline, Budget) of
        {<<"wait-resumed-marker">>, _} -> ok;
        {_, Left} -> wait_marker(Port, Deadline, Left)
    end.

control_line(Port, Deadline, Budget) when Budget > 0 ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, {eol, Line}}} -> {Line, Budget - byte_size(Line) - 1};
        {Port, {data, {noeol, _}}} -> error(control_line_limit);
        {Port, {exit_status, Status}} -> error({control_exit, Status})
    after Remaining -> error(control_event_timeout)
    end;
control_line(_, _, _) -> error(control_output_limit).
