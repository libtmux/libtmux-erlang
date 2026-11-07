-module(pane_demo).
-moduledoc "Isolate a running pane, then join it back without respawning.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    try
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"pane-workflow">>, window_name => <<"editor">>,
              launch => #{argv => [<<"/bin/cat">>]}}),
        try
            {ok, Initial} = tmux_server:snapshot(Server),
            {ok, Link} = tmux_select:one(
                #{session_id => tmux_model:get(id, Session)},
                tmux_select:window_links(Initial)),
            {ok, Window} = tmux_snapshot:related(window, Link, Initial),
            {ok, [Anchor]} = tmux_snapshot:related(panes, Window, Initial),
            WindowId = tmux_model:get(id, Window),
            {ok, Pane} = tmux_pane:split(Anchor,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            Id = tmux_model:get(id, Pane),
            Pid = tmux_model:get(pid, Pane),
            {ok, Before} = tmux_server:snapshot(Server),
            {ok, _} = tmux_pane:break(Pane, Link, Session,
                #{index => 9, name => <<"isolated #{pane_id}">>}),
            {ok, Isolated} = tmux_pane:get(Server, Id),
            Pid = tmux_model:get(pid, Isolated),
            Temporary = tmux_model:get(window_id, Isolated),
            true = Temporary =/= WindowId,
            {ok, OldPane} = tmux_snapshot:get(pane, Id, Before),
            WindowId = tmux_model:get(window_id, OldPane),
            {ok, _} = tmux_pane:join(Pane, Anchor,
                #{direction => horizontal, size => {percent, 40}}),
            {ok, Joined} = tmux_pane:get(Server, Id),
            WindowId = tmux_model:get(window_id, Joined),
            Pid = tmux_model:get(pid, Joined),
            {error, #{code := target_gone}} =
                tmux_window:get(Server, Temporary),
            {ok, Final} = tmux_server:snapshot(Server),
            2 = length(tmux_snapshot:panes(Final)),
            #{same_process => true, snapshot_unchanged => true,
              temporary_window_removed => true, panes_after_join => 2}
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
