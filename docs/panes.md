# Isolate and rejoin a running pane

Move a job into its own window, then join it back without respawning it.
This complete program checks the process ID, changed parent window, removal of
the temporary window and immutability of the earlier capture. The runner owns
the server and verifies cleanup:

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

The archive check repeats this reader program outside the source checkout.
Its separate native consumer also exercises same-window move and pane swap.

## Supply a membership when breaking a pane

A physical window can be linked several times, even within one session. A pane
therefore has no single source membership. `tmux_pane:break/4` takes the pane,
an explicit source window link, the destination session and placement options.
`index` is required. `detach` defaults to true; false selects the destination
membership. `name` is a literal UTF-8 argument, without format expansion.

| Source window | What tmux changes |
| --- | --- |
| Several panes | Creates a physical window and moves the pane into it; the original links remain |
| Only one pane | Moves the selected membership of the existing physical window; other links remain |

Pane IDs and running processes survive both cases. Moving the final membership
out of a session can destroy that source session. Session groups retain tmux's
native synchronization behavior. An occupied destination index is refused.

The API checks the link's expected window and the pane's observed parent. It
then sends a session/index selector qualified by the stable pane ID. An absent
pane cannot become whichever pane later occupies its old positional index.
The preflight and action remain separate commands: concurrent changes after
the check, including an index moving away and back, can remain undetected.
There is no atomic compare-and-act guarantee.

Literal means unexpanded, not stored verbatim. tmux's own name cleaning still
applies. For example, 3.3/3.4 stores an added backslash before dollar-variable
prefixes; later releases changed that behavior. The library returns the
stored name instead of guessing which escapes a caller intended. See the
[object graph guide](graph.md) for physical windows and memberships.

## Move and swap by physical pane ID

`tmux_pane:join/3` and `tmux_pane:move/3` use the source and destination pane
IDs. Their native commands share placement behavior and permit rearrangement
within one window. Geometry uses `t:tmux_pane:join_options/0`: vertical by
default, optional direction, cells/percent size, `before` and `full_size`.
Both reject identical source/destination IDs.

`tmux_pane:swap/3` exchanges layout positions within or across windows. Its
`detach` defaults to true; `zoom` maps to tmux's `-Z` retention flag. Swapping
a pane with itself exchanges nothing, but native zoom handling still runs:
the default can unzoom even that same-pane call. Across windows, active
positions can receive different pane IDs even in detached mode.

Moving the last pane out destroys its physical window and every link to it,
and can remove sessions. Shared windows affect all memberships. Existing
processes keep their process environment and working directory; inherited
window options can change when the pane changes parent. With `detach` false,
join/move selection uses tmux's resolved destination-session context. Supply
window-link actions separately when a particular session membership must be
selected.

## Keep captures and action results separate

These calls return the completed command result for both new-window and
existing-window cases. They never refresh input records or captures. Use
`tmux_pane:get/2`, `tmux_window_link:get/3` or `tmux_server:snapshot/1` to observe
the resulting graph. Source/destination rows must use the same registered
owner; rebind explicitly when working through another endpoint owner.

A disappeared pane or session remains an operational error. A replaced source
link returns `stale_link`; a different observed pane parent returns
`pane_link_mismatch`. Even an eventual native layout error can unzoom windows.
These operations are not transactions and are never automatically retried.
The [support page](compatibility.md) separates implemented APIs from remaining
control, consumer and delivery qualification.
