# Query a shared window without losing its memberships

This program creates two sessions, a shared two-pane window, and two extra
window links. It then checks the physical object graph and session-relative
membership counts. `tmux_window_link` acts on a session/index membership and
checks its expected physical window before dispatch.

Selecting a window membership changes that session's current window.
`tmux_session:select/2` switches one explicitly named attached client to a
session. It never attaches a client or chooses a current client implicitly.
Its `tmux_session:select/3` variant updates the destination environment only
when requested. Client names can be reused after disconnection; this call
does not provide an atomic client-incarnation check. The native API contract
documents name lookup and environment-removal semantics.

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

There are three physical windows and four physical panes. Five window links
remain because the shared window occurs at two indexes in `work` and once
in `mirror`. The windows relationship yields two unique windows for `work`;
its window_links relationship retains all three memberships. Both traversals
use `tmux_snapshot:related/3`.

A link is identified within a capture by session, index and expected physical
window. It has no stable tmux link ID. Captured index references cannot promise
atomic compare-and-act after another client moves a link.

Use `tmux_window_link:get/3` for a fresh membership. `link/3` adds a membership;
`move/3` moves just the checked membership; `swap/3` exchanges two memberships'
physical windows. Their input rows must share one registered owner. Actions
return command results and leave captured values unchanged.

`select/1` selects the checked window in its session. `unlink/2` removes one
membership, retaining tmux's last-link protection by default. Explicit
`force => true` can destroy the physical window if its final membership goes.
`tmux_window:kill/1` destroys that window across all links.

If a captured index disappears or names another physical window, actions
return `stale_link` before dispatch. `tmux_server:bind/2` applies this same
precondition when rebinding a link to an owner. It does not adopt the new
occupant of an old index. The one-shot preflight and action are separate;
another client can still change that membership between them.

The relation query checks the full captured graph. Filtering a window selection
does not replace its panes with only matching panes. `some`, `every`, `none`
and `count` require complete membership coverage, including empty selections.
The [query guide](querying.md) explains validation and correlation.
