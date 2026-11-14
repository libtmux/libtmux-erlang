# Own a control attachment

Attach to an existing session, verify identity on that persistent connection,
inspect its attachment effects and close the client.

- This covers the connection's lifetime only. Commands still run through the
  one-shot APIs.
- Control command submission and groups are not built.

The program owns its session. The runner supplies a private tmux server:

```console
$ mise exec -- escript tools/run_examples.escript control
```

<!-- example: examples/control_demo.erl -->

```erlang
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
```

<!-- example-output: control_demo -->

```json
{
  "identity": "same_connection",
  "attached_count": 1,
  "detached_count": 0,
  "window_size": [120, 30],
  "cleanup": "complete",
  "session_preserved": true
}
```

- The session record you captured first keeps its attached count of zero.
  Fresh reads show one attachment, then none after detach.
- `ignore-size` keeps the window at 120 by 30.
- With no mutating hooks, closing the client leaves the session and daemon.

## What attaching does

- The session must be captured or bound through the same endpoint. A second
  handle to the same socket returns `different_owner`.
- The library runs `attach-session` with no-output, ignore-size and `-E`. It
  issues no session-creation or session-option writes.
- `-E` skips the native environment update. Attaching changes `attached_count`.
- On tmux 3.6 and newer it also uses no-detach-on-destroy. Earlier versions
  keep native destruction behavior.
- Configured attach or detach hooks can still change state, create or destroy
  resources. A destroy-unattached policy can remove the session when its last
  client detaches. Failure and cleanup do not roll these effects back.
- Other clients can change state at the same time.

## Lifetime and cleanup

- The caller owns the control lifetime. Caller death, closing the parent or
  invalidating it requests retirement.
- Close the control handle before its parent endpoint when cleanup proof
  matters. Closing the parent proves its one-shot clients' cleanup. It does not
  wait for control clients.
- `tmux_control:close/1` returns `ok` only after the native client and helper
  retire. Close issues no session or daemon destruction commands.
- On `cleanup_incomplete`, a supervised owner stays. Keep the handle, fix the
  problem and retry `close/1`.
- `status/1` tells `closing` from `closed` and reports cleanup. A closed handle
  answers `status/1` and a repeated `close/1` for 60 seconds.
- Stopping the application alone does not prove cleanup.
- Unexpected hook output or reply blocks reject the attachment and retire the
  client. The library does not disable borrowed hooks.
- Startup is bounded across parent registration, native exec and the identity
  probe. An incomplete error carries the control handle for recovery.

See [daemon ownership](ownership.md) for private versus borrowed lifetimes,
[jobs](jobs.md) for one-shot waits and cancellation, and
[support and gaps](compatibility.md) for what is exercised.
