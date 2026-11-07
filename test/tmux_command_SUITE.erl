-module(tmux_command_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, literal_arguments/1, singleton_argv/1]).

%% Outer: tmux argv/format parsing and singleton pane-command execution.
all() -> [literal_arguments, singleton_argv].

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
