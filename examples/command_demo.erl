-module(command_demo).
-moduledoc "Build captured-target commands, then execute and inspect them.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    try
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"commands">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        try
            SessionId = tmux_model:get(id, Session),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            [Anchor] = tmux_snapshot:panes(Snapshot),
            {ok, Pane} = tmux_pane:split(Anchor,
                #{direction => horizontal, size => {cells, 40},
                  launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, Rename} = tmux_session:rename_command(
                Session, <<"commands-ready">>),
            {ok, Resize} = tmux_pane:resize_command(Pane, #{width => 60}),
            {ok, OtherEndpoint} = tmux_server:open(Endpoint),
            try
                {error, #{code := different_owner, submitted := false}} =
                    tmux_server:command(OtherEndpoint, Rename, #{})
            after
                ok = tmux_server:close(OtherEndpoint)
            end,
            {ok, Before} = tmux_session:get(Server, SessionId),
            <<"commands">> = tmux_model:get(name, Before),
            40 = tmux_model:get(width, Pane),
            {ok, #{exit_status := 0, cleanup := complete}} =
                tmux_server:command(Server, Rename, #{}),
            {ok, Operation} = tmux_operation:start(Server, Resize, #{}),
            {ok, #{exit_status := 0, cleanup := complete}} =
                tmux_operation:await(Operation, 900),
            {ok, Current} = tmux_pane:get(Server, tmux_model:get(id, Pane)),
            60 = tmux_model:get(width, Current),
            {ok, Renamed} = tmux_session:get(Server, SessionId),
            <<"commands-ready">> = tmux_model:get(name, Renamed),
            <<"commands">> = tmux_model:get(name, Session),
            40 = tmux_model:get(width, Pane),
            #{name => <<"commands-ready">>, initial_width => 40,
              actual_width => 60, captured_values_unchanged => true,
              foreign_origin_rejected => true}
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
