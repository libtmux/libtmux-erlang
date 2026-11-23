# Own a control attachment

Attach to an existing session, verify identity on that persistent connection,
inspect its attachment effects and close the client.

Receive pane bytes on a [separate stream attachment](#read-pane-output).
Hex 0.0.3 supports streams on owned servers. The source checkout also
supports [command groups](#change-a-session-and-its-window) on owned servers
and streams on borrowed servers. The one-shot APIs cover the general command
catalogue.

The program owns its session. The runner supplies a private tmux server:

```console
$ escript scripts/check/run_examples.escript control
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

## Submit a read group

Use `tmux_control:submit/3` on an attachment to a private daemon started by
`tmux_server:with_owned/2`. The attachment owner submits one group at a
time and receives a handle before tmux replies. The replies below contain
the session IDs and the pane IDs in the selected session's current window.

<!-- example: examples/control_read_demo.erl#submit -->

```erlang
{ok, Sessions} = tmux_command:raw(<<"list-sessions">>,
    [<<"-F">>, <<"#{session_id}">>]),
{ok, Panes} = tmux_command:raw(<<"list-panes">>,
    [<<"-t">>, SessionId, <<"-F">>, <<"#{pane_id}">>]),
{ok, Read} = tmux_control:submit(Control, [Sessions, Panes], #{}),
{ok, #{replies := [SessionIds, PaneIds]}} = tmux_control:await(Read, 900),
```

Run the [complete example](../examples/control_read_demo.erl) to check both
counts, resize the window and retire the attachment and daemon.

```console
$ escript scripts/check/run_examples.escript control-read
```

<!-- example-output: control_read_demo -->

```json
{
  "panes": 1,
  "sessions": 1,
  "window_width": 110,
  "cleanup": "complete"
}
```

## Change a session and its window

Build commands from rows captured on the attached endpoint. This example
renames the session and sets the window width in one group.

<!-- example: examples/control_read_demo.erl#mutate -->

```erlang
{ok, Rename} = tmux_session:rename_command(Session, <<"resized">>),
{ok, Resize} = tmux_window:resize_command(Window, #{width => 110}),
{ok, Work} = tmux_control:submit(Control, [Rename, Resize], #{}),
{ok, #{replies := [<<>>, <<>>]}} = tmux_control:await(Work, 900),
```

A successful mutation returns an empty binary. The example reads the
session and window again to check the actual name and geometry. You can
also build a pane resize with `tmux_pane:resize_command/2`.

Groups accept up to 16 qualified reads or mutations and 64 KiB of replies.
Pass a list or a value from `tmux_command:sequence/1`. When a target is
missing, tmux skips the remaining members. The result includes the failed
member's index and prior replies. Successful mutations in that prefix
still take effect.

Keep the admitted command spellings and `display-message` at their native
meanings. Configured aliases can override full command names. An unexpected
reply or hook frame retires the attachment. The error retains confirmed
replies and reports an unknown outcome for the rest. Check the target before
deciding whether to submit another mutation.

`tmux_control:await/2` timing out leaves the group running. Cancelling a
running group retires the attachment. If the result reports incomplete
cleanup, await it again to observe later retirement. Attach again to submit
another group.

## Read pane output

Use `tmux_stream:subscribe/3` with a session captured on an owned or borrowed
endpoint. The separate client uses the same-connection daemon and session
check. Attaching skips environment updates and ignores its size. Native
attach and detach hooks still run. Keep `attach-session` and `display-message`
at their native meanings for the attachment and its identity check.

The example subscribes before sending input and waits for the bytes
`hello\r\n` from one pane. Its outer scope stops the private server.

<!-- example: examples/stream_demo.erl#subscribe -->

```erlang
{ok, Subscription} = tmux_stream:subscribe(Server, Session, #{}),
tmux_scope:run_or_error(fun() ->
    {error, #{code := credit_limit}} =
        tmux_stream:demand(Subscription, #{bytes => 1, messages => 1}),
    {ok, _} = tmux_pane:send_text(Pane, <<"go\n">>),
    Deadline = erlang:monotonic_time(millisecond) + 900,
    ok = receive_bytes(Subscription, PaneId, Expected, Deadline),
    Expected
end, fun() -> tmux_stream:close(Subscription) end).
```

Run the [full example](../examples/stream_demo.erl) from the compiled checkout.

```console
$ escript scripts/check/run_examples.escript stream
```

<!-- example-output: stream_demo -->

```json
{
  "pane_output": "hello\r\n",
  "cleanup": "complete"
}
```

- `{pane_output, PaneId, Bytes}` carries raw terminal bytes. Other native
  notifications carry their name and fields as binaries. Fetch a fresh
  snapshot when you need current session, window or pane state.
- The command attachment's `no-output` flag applies to that client. The
  stream leaves pane output enabled. If tmux reports paused pane output
  or sends extended output, the stream retires with a gap.
- `tmux_stream:ack/3` frees the exact event's capacity. Request more credit
  for future events with `tmux_stream:demand/2`. Each subscriber has up to
  64 KiB and eight messages, including events waiting for acknowledgement.
- The default subscription starts with full credit. The example checks
  the `credit_limit` error before reading any events.
- A client admits up to 16 subscriptions, for at most 1 MiB and 128 messages
  of total credit. The byte count covers event data and identifiers.
- `tmux_stream:join/2` shares the client with another process. A slow
  subscriber gets a terminal gap while others can keep reading. Closing
  the last subscription waits for native client and helper retirement.
- A gap reports the last delivered sequence and an unknown loss extent.
  Start a new subscription for subsequent bytes. Use `tmux_pane:capture/2`
  for the current rendered screen.

See [daemon ownership](ownership.md) for private versus borrowed lifetimes,
[jobs](jobs.md) for one-shot waits and cancellation, and
[support and gaps](compatibility.md) for what is exercised.
