-module(control_demo).
-moduledoc "Attach explicitly, inspect captured values and prove detachment.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"control-demo">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            Id = tmux_model:get(id, Session),
            0 = tmux_model:get(attached_count, Session),
            {ok, Control} = tmux_control:attach(Server, Session, #{}),
            tmux_scope:run_or_error(fun() ->
                {ok, #{phase := open, identity := same_connection}} =
                    tmux_control:status(Control),
                {ok, Attached} = tmux_session:get(Server, Id),
                1 = tmux_model:get(attached_count, Attached),
                {ok, Graph} = tmux_server:snapshot(Server),
                [Window] = tmux_snapshot:windows(Graph),
                120 = tmux_model:get(width, Window),
                30 = tmux_model:get(height, Window),
                ok = tmux_control:close(Control),
                {ok, #{phase := closed, cleanup := complete}} =
                    tmux_control:status(Control),
                {ok, Detached} = tmux_session:get(Server, Id),
                0 = tmux_model:get(attached_count, Detached),
                0 = tmux_model:get(attached_count, Session),
                #{identity => same_connection, attached_count => 1,
                  detached_count => 0, window_size => [120, 30],
                  cleanup => complete, session_preserved => true}
            end, fun() ->
                ok = tmux_control:close(Control)
            end)
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
