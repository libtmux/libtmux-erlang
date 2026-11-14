# Isolate and rejoin a running pane

Move a job into its own window, then join it back without respawning it.

The program checks the process ID, the changed parent window, the removal of
the temporary window and that the earlier capture did not change. The runner
supplies the server:

```console
$ mise exec -- escript tools/run_examples.escript panes
```

<!-- example: examples/pane_demo.erl -->

```erlang
-module(pane_demo).
-moduledoc "Isolate a running pane, then join it back without respawning.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"pane-workflow">>, window_name => <<"editor">>,
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
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
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

<!-- example-output: pane_demo -->

```json
{
  "same_process": true,
  "snapshot_unchanged": true,
  "temporary_window_removed": true,
  "panes_after_join": 2
}
```

## Break a pane out of a window

- A physical window can be linked several times, even in one session, so a
  pane has no single source membership. `tmux_pane:break/4` takes the pane, an
  explicit source window link, the destination session and placement options.
- `index` is required. `detach` defaults to true; false selects the
  destination membership.
- `name` is a literal UTF-8 argument with no format expansion.

| Source window | What tmux changes |
| --- | --- |
| Several panes | Creates a physical window and moves the pane into it; the original links remain |
| Only one pane | Moves the selected membership of the existing physical window; other links remain |

- Pane IDs and running processes survive both cases.
- Moving the final membership out of a session can destroy that session.
  Session groups keep tmux's native synchronization.
- An occupied destination index is refused.
- Literal means unexpanded, not stored verbatim. tmux's own name cleaning still
  applies: 3.3 and 3.4 add a backslash before dollar-variable prefixes, and
  later releases changed that. The library returns the stored name.
- The call checks the link's expected window and the pane's observed parent,
  then sends a session and index selector qualified by the stable pane ID. An
  absent pane cannot turn into whichever pane later takes its old index.
- The check and the action are separate commands. A concurrent change after the
  check, such as an index moving away and back, can go unnoticed. There is no
  atomic compare-and-act.

See the [object graph guide](graph.md) for physical windows and memberships.

## Move and swap by pane ID

- `tmux_pane:join/3` and `tmux_pane:move/3` take source and destination pane
  IDs. They share placement behavior and allow rearranging within one window.
- Geometry comes from `t:tmux_pane:join_options/0`: vertical by default, an
  optional direction, cell or percent size, `before` and `full_size`.
- Both reject identical source and destination IDs.
- `tmux_pane:swap/3` swaps layout positions within or across windows.
  `detach` defaults to true. `zoom` maps to tmux's `-Z`.
- Swapping a pane with itself moves nothing, but native zoom handling still
  runs, so the default can unzoom even then.
- Across windows, active positions can get different pane IDs even in detached
  mode.
- Moving the last pane out destroys its physical window and every link to it,
  and can remove sessions. A shared window affects all its memberships.
- Existing processes keep their environment and working directory. Inherited
  window options can change when a pane changes parent.
- With `detach` false, join and move select in tmux's resolved destination
  session. Use window-link actions when you need a particular membership.

## Keep captures and results separate

- These calls return the completed command result for new-window and
  existing-window cases. They never refresh input records or captures.
- Observe the result with `tmux_pane:get/2`, `tmux_window_link:get/3` or
  `tmux_server:snapshot/1`.
- Source and destination rows must share one registered owner. Rebind to work
  through another endpoint.
- A vanished pane or session is an operational error. A replaced source link
  returns `stale_link`. A different observed pane parent returns
  `pane_link_mismatch`.
- A late native layout error can still unzoom windows.
- These operations are not transactions and are never retried.

See the [support page](compatibility.md) for what is not built.
