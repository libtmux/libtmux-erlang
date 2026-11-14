-module(typing_demo).
-moduledoc "Type a command into a shell pane, wait for it, read the screen.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    {ok, Result} = tmux_server:with_owned(#{executable => Executable},
        fun(Server) ->
            Shell = #{argv => [<<"/bin/sh">>]},
            {ok, _} = tmux_session:create(Server, #{name => <<"typing">>,
                width => 120, height => 30, launch => Shell}),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            [Pane] = tmux_snapshot:panes(Snapshot),
            % The shell signals a tmux channel once it has printed.
            {ok, Wait} = tmux_command:wait_for(<<"typed">>, wait),
            {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
            Signal = <<"'", Executable/binary, "' wait-for -S typed">>,
            Line = <<"echo hello; ", Signal/binary>>,
            {ok, _} = tmux_pane:send_text(Pane, Line),
            {ok, _} = tmux_pane:send_keys(Pane, [enter]),
            {ok, _} = tmux_operation:await(Operation, 2000),
            {ok, Screen} = tmux_pane:capture(Pane, #{}),
            Rows = binary:split(Screen, <<"\n">>, [global]),
            true = lists:member(<<"hello">>, Rows),
            #{typed => <<"echo hello">>, screen_row => <<"hello">>}
        end),
    Result.
