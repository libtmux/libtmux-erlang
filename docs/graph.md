# Query a shared window without losing its memberships

This program creates two sessions, a shared two-pane window, and two extra
window links. It then checks the physical object graph and session-relative
membership counts. The raw `link-window` command is a trusted escape hatch;
a typed link facade is still part of the unfinished command surface.

Run it on a private server after compiling:

```console
$ mise exec -- escript tools/run_examples.escript graph
```

<!-- example: examples/linked_graph.erl -->

```erlang
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
                MirrorId = tmux_model:get(id, Mirror),
                WindowId = tmux_model:get(id, Shared),
                lists:foreach(fun(Target) ->
                    {ok, Link} = tmux_command:raw(<<"link-window">>,
                        [<<"-d">>, <<"-s">>, WindowId, <<"-t">>, Target]),
                    {ok, _} = tmux_server:command(Server, Link, #{})
                end, [<<WorkId/binary, ":7">>, <<MirrorId/binary, ":9">>]),
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
```

There are three physical windows and four physical panes. Five window links
remain because the shared window occurs at two indexes in `work` and once
in `mirror`. `Session.windows` projects two unique windows for `work`;
`Session.window_links` retains its three memberships.

A link is identified within a capture by session, index and expected physical
window. It has no stable tmux link ID. Captured index references cannot promise
atomic compare-and-act after another client moves a link.

The relation query checks the full captured graph. Filtering a window selection
does not replace its panes with only matching panes. `some`, `every`, `none`
and `count` require complete membership coverage, including empty selections.
The [query guide](querying.md) explains validation and correlation.
