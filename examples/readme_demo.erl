-module(readme_demo).
-moduledoc "Create a workspace, query its graph and preserve captured values.".
-export([run/2]).
-import_record(tmux_model, [pane]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    try
        {ok, Session} = tmux_session:create(Server, #{name => <<"workspace">>,
            window_name => <<"editor">>, width => 120, height => 30,
            launch => #{argv => [<<"/bin/cat">>]}}),
        try
            {ok, Worker} = tmux_window:create(Session,
                #{name => <<"workers">>,
                  launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, Right} = tmux_pane:split(Worker, #{direction => horizontal,
                launch => #{argv => [<<"/bin/cat">>]}}),
            {ok, _} = tmux_window:select_layout(Worker, even_horizontal),
            {ok, _} = tmux_pane:resize(Right, #{width => 40}),
            {ok, Snapshot} = tmux_server:snapshot(Server),
            Windows = tmux_select:windows(Snapshot),
            Workers = #{name => <<"workers">>, panes => #{count => 2,
                every => #{current_command => <<"cat">>}}},
            {ok, Captured} = tmux_select:one(Workers, Windows),
            {ok, Children} = tmux_snapshot:related(panes, Captured, Snapshot),
            Ids = [Id || #pane{id = Id} <:- Children],
            2 = length(Ids),
            Criteria = #{width => #{gte => 20},
                window => #{is => #{name => <<"workers">>}}},
            Query = tmux_query:where(Criteria, tmux_query:panes(Server)),
            {ok, Fetched} = tmux_query:fetch(Query),
            2 = tmux_select:size(Fetched),
            {ok, _} = tmux_window:rename(Worker, <<"finished">>),
            <<"workers">> = tmux_model:get(name, Captured),
            {ok, Fresh} = tmux_query:fetch(tmux_query:where(
                #{name => <<"finished">>}, tmux_query:windows(Server))),
            {ok, Renamed} = tmux_select:one(Fresh),
            <<"finished">> = tmux_model:get(name, Renamed),
            1 = length(tmux_snapshot:sessions(Snapshot)),
            2 = length(tmux_snapshot:windows(Snapshot)),
            3 = length(tmux_snapshot:panes(Snapshot)),
            #{sessions => 1, windows => 2, panes => 3, matched_panes => 2,
              captured_name => <<"workers">>, immutable => true}
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
