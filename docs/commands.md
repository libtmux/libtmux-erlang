# Build commands before running them

Prepare a session rename and a pane resize, then submit them explicitly.
Building validates the captured target and arguments without contacting tmux.
Execution checks the endpoint origin and returns the native one-shot result.

The program checks the name before execution, awaits the resize through an
operation handle, reads fresh dimensions and verifies that earlier rows keep
their values. The runner supplies the private server:

```console
$ mise exec -- escript tools/run_examples.escript commands
```

<!-- example: examples/command_demo.erl -->

```erlang
-module(command_demo).
-moduledoc "Build captured-target commands, then execute and inspect them.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"commands">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
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
            tmux_scope:run_or_error(fun() ->
                {error, #{code := different_owner, submitted := false}} =
                    tmux_server:command(OtherEndpoint, Rename, #{})
            end, fun() ->
                ok = tmux_server:close(OtherEndpoint)
            end),
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
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

<!-- example-output: command_demo -->

```json
{
  "name": "commands-ready",
  "initial_width": 40,
  "actual_width": 60,
  "captured_values_unchanged": true,
  "foreign_origin_rejected": true
}
```

- `tmux_session:rename/2` and `tmux_pane:resize/2` act at once. Their
  `_command` builders return reusable values.
- Reusing a value needs explicit intent each time.
- Never retry an uncertain mutation automatically.

## Keep the endpoint

- A command keeps its row's endpoint token. Submitting it through another
  endpoint returns `different_owner` with `submitted = false`, even when both
  endpoints use the same pane or session ID. The program checks this with a
  second handle to the same daemon.
- To act through another endpoint, bind the row there and build a new command.
  Bind a detached row with `tmux_server:bind/2` first.
- Building does not check that the endpoint is alive.

## Render without running

- `tmux_command:to_config/1` renders command syntax without executing it.
- Rendered configuration carries no origin token. Choose and validate the
  destination yourself.

See [jobs and operations](jobs.md) for wait timeouts, ownership and
cancellation, the [configuration guide](configuration.md) for rendering, and
[current support](compatibility.md) for transport limits.
