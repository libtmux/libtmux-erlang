# Own a control attachment

Attach to an existing session, verify identity on that persistent connection,
inspect its attachment effects and close the client. This currently qualifies
connection lifetime only. Commands still execute through the one-shot APIs;
control submission and groups remain implementation work.

The example owns its session. The runner provides a private tmux fixture and
verifies final cleanup:

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
    try
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"control-demo">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        try
            Id = tmux_model:get(id, Session),
            0 = tmux_model:get(attached_count, Session),
            {ok, Control} = tmux_control:attach(Server, Session, #{}),
            try
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
            after
                ok = tmux_control:close(Control)
            end
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
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

The archive check repeats this complete program through the installed core
package. The initial session record keeps its captured count of zero; fresh
reads observe one attachment and later detachment. ignore-size preserves the
120-by-30 window. In this isolated fixture without mutating hooks, closing the
client preserves the session and daemon.

An attachment requires a session captured or bound through the same endpoint.
A second endpoint handle returns different_owner even for the same socket.
The library uses attach-session with no-output, ignore-size and `-E`. It
issues no session-creation or session-option write commands. `-E` skips the
native attachment environment update. Configured attachment/detachment hooks
can still change state, create or destroy resources. Native policies such as
destroy-unattached can remove a session when its last client detaches. Failure
and cleanup do not roll back those effects. Other clients may also change
state concurrently. Close retires its client/helper without issuing session
or daemon destruction commands.
Attachment changes attached_count. On tmux 3.6 and newer it also uses
no-detach-on-destroy; earlier versions retain native destruction behavior.

The caller owns the control lifetime. Caller death, parent closing or parent
invalidation requests retirement. Close the control handle before closing
its parent endpoint when cleanup proof matters. Parent close proves its
one-shot clients' cleanup; it does not wait for separate control clients.

`tmux_control:close/1` returns ok only after native client/helper retirement.
cleanup_incomplete preserves a supervised owner: retain the handle and retry
close after repairing the cleanup problem. status distinguishes closing from
closed and reports cleanup explicitly. Successfully closed handles remain
usable for status and idempotent close for 60 seconds. Application shutdown
alone does not prove cleanup.

Unexpected hook output or reply blocks reject attachment and retire the client.
The library does not disable borrowed hooks. Bounded startup includes parent
registration, native exec and the identity probe. An incomplete error carries
its control handle for explicit cleanup recovery.

See [daemon ownership](ownership.md) for private versus borrowed lifetimes,
[jobs](jobs.md) for one-shot operation waits and cancellation, and
[support and gaps](compatibility.md) for matrix and delivery evidence.
