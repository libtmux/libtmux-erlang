# Query a shared window without losing its memberships

Build two sessions, a shared two-pane window and two extra links to it. Then
count physical objects and session memberships.

- A window link is one session and index. A physical window can have many.
- `tmux_window_link` acts on one link and checks its expected window first.

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
    tmux_scope:run_or_error(fun() ->
        {ok, Work} = tmux_session:create(Server,
            #{name => <<"work">>, launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            {ok, Mirror} = tmux_session:create(Server,
                #{name => <<"mirror">>, launch => #{argv => [<<"/bin/cat">>]}}),
            tmux_scope:run_or_error(fun() ->
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
            end, fun() ->
                {ok, _} = tmux_session:kill(Mirror),
                ok
            end)
        end, fun() ->
            {ok, _} = tmux_session:kill(Work),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

- The graph has 3 physical windows, 4 physical panes and 5 window links. The
  shared window sits at two indexes in `work` and one in `mirror`.
- For `work`, `tmux_snapshot:related/3` returns 2 unique windows through
  `windows` and all 3 memberships through `window_links`.

## Act on a membership

- `tmux_window_link:get/3` reads a fresh membership.
- `link/3` adds one. `move/3` moves just the checked membership. `swap/3`
  exchanges two memberships' physical windows.
- Input rows must share one registered owner.
- `select/1` selects the checked window, which changes that session's current
  window.
- `unlink/2` removes one membership. tmux's last-link protection stays on
  unless `force => true`, which can destroy the physical window.
- `tmux_window:kill/1` destroys the window across all links.
- Actions return command results and leave captured values unchanged.

## Expect stale links

- tmux gives a link no ID. A capture identifies it by session, index and
  expected physical window.
- If the index vanished or names another window, an action returns
  `stale_link` before dispatch. `tmux_server:bind/2` applies the same check;
  it does not adopt the index's new occupant.
- The check and the action are separate commands. Another client can still
  change the link between them.

## Switch a client

- `tmux_session:select/2` switches one named, attached client to a session. It
  never attaches a client or picks one for you.
- `tmux_session:select/3` updates the destination environment only on request.
- Client names can be reused after a disconnect, and the call does not check
  the client's incarnation.

## Filter by relation

- A relation query checks the full captured graph. Filtering windows does not
  trim their panes to the matching ones.
- `some`, `every`, `none` and `count` need complete membership coverage,
  including empty selections.

More: [query guide](querying.md).

## Compare captured server incarnations

- Live `tmux_snapshot:metadata/1` holds an opaque `server_instance` value.
  `tmux_identity:fingerprint/1` turns it into a versioned binary key without
  I/O.
- The key survives reconnecting through another endpoint handle and changes
  when the observed process changes.
- An endpoint generation identifies one handle's lifetime. The key compares
  the servers those handles observed.
- A key cannot make a stale row actionable, show liveness or authorize an
  action. Use `tmux_server:bind/2` for a fresh actionable row.
