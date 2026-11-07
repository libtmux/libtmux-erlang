-module(linked_graph).
-moduledoc "Distinguish physical windows from their session memberships.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    try
        {ok, Work} = tmux_session:create(Server,
            #{name => <<"work">>, launch => #{argv => [<<"/bin/cat">>]}}),
        try
            {ok, Mirror} = tmux_session:create(Server,
                #{name => <<"mirror">>, launch => #{argv => [<<"/bin/cat">>]}}),
            try
                {ok, Shared} = tmux_window:create(Work,
                    #{name => <<"shared">>,
                      launch => #{argv => [<<"/bin/cat">>]}}),
                Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
                {ok, _} = tmux_pane:split(Shared, Launch),
                WorkId = tmux_model:get(id, Work),
                WindowId = tmux_model:get(id, Shared),
                {ok, Before} = tmux_server:snapshot(Server),
                {ok, Source} = tmux_select:one(#{window_id => WindowId},
                    tmux_select:window_links(Before)),
                {ok, _} = tmux_window_link:link(Source, Work, #{index => 7}),
                {ok, _} = tmux_window_link:link(
                    Source, Mirror, #{index => 9}),
                {ok, Snapshot} = tmux_server:snapshot(Server),
                3 = length(tmux_snapshot:windows(Snapshot)),
                4 = length(tmux_snapshot:panes(Snapshot)),
                5 = length(tmux_snapshot:window_links(Snapshot)),
                {ok, CapturedWork} = tmux_snapshot:get(
                    session, WorkId, Snapshot),
                {ok, Physical} = tmux_snapshot:related(
                    windows, CapturedWork, Snapshot),
                {ok, Memberships} = tmux_snapshot:related(
                    window_links, CapturedWork, Snapshot),
                2 = length(Physical),
                3 = length(Memberships),
                Criteria = #{window_links => #{count => 3},
                    panes => #{every => #{current_command => <<"cat">>},
                        count => 2}},
                {ok, Only} = tmux_select:one(
                    Criteria, tmux_select:windows(Snapshot)),
                WindowId = tmux_model:get(id, Only),
                #{physical_windows => 3, physical_panes => 4, window_links => 5,
                  work_windows => 2, work_memberships => 3,
                  shared_window_panes => 2}
            after
                {ok, _} = tmux_session:kill(Mirror)
            end
        after
            {ok, _} = tmux_session:kill(Work)
        end
    after
        ok = tmux_server:close(Server)
    end.
