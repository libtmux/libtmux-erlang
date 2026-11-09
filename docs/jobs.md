# Wait for a terminal job, then capture its output

A successful send or command frame does not prove that a terminal program
processed input. This example runs an owned job that acknowledges terminal
parsing before it exits, then waits for tmux's `pane-died` event, checks the
exit status and captures the completed output.

The companion [terminal job](../examples/terminal_job.py) writes its result and
an ANSI device-status request. It exits successfully only after reading tmux's
reply. tmux generates that reply after parsing the preceding output. The job
writes no more output afterward. Python 3.12+ is an example dependency only.

`pane-died` alone is **not** a general output-drain barrier on tmux 3.3. This
protocol applies to this cooperating job; it does not establish completion for
an arbitrary program or reconstruct output that scrolled out of history.

The example changes options and a hook only on its new window. `remain-on-exit`
keeps the pane addressable; an empty exit banner preserves the first line.
The hook signals a tmux `wait-for` channel. There are no sleeps or capture
retries. Run from the checkout so the companion job can be located:

```console
$ mise exec -- escript tools/run_examples.escript job
```

<!-- example: examples/job_demo.erl -->

```erlang
-module(job_demo).
-moduledoc "Capture a job that acknowledges terminal parsing before it exits.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Endpoint = #{socket_path => Socket, executable => Executable},
    {ok, Server} = tmux_server:open(Endpoint),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"jobs">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            {ok, Window} = tmux_window:create(Session,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            Target = [<<"-w">>, <<"-t">>, tmux_model:get(id, Window)],
            Deadline = #{deadline_ms => 2000},
            {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
            {ok, _} = tmux_option:set(
                Window, <<"remain-on-exit-format">>, <<>>),
            {ok, Hook} = tmux_command:raw(<<"set-hook">>,
                Target ++ [<<"pane-died">>, <<"wait-for -S job-finished">>]),
            {ok, _} = tmux_server:command(Server, Hook, #{}),
            {ok, Wait} = tmux_command:raw(<<"wait-for">>, [<<"job-finished">>]),
            {ok, Operation} = tmux_operation:start(Server, Wait, Deadline),
            {error, #{code := await_timeout}} =
                tmux_operation:await(Operation, 0),
            JobFile = filename:absname("examples/terminal_job.py"),
            Launch = #{argv => [<<"/usr/bin/python3">>,
                list_to_binary(JobFile)]},
            {ok, Job} = tmux_pane:split(Window, #{launch => #{shell => <<>>}}),
            {ok, _} = tmux_pane:respawn(Job, #{launch => Launch}),
            {ok, #{exit_status := 0, cleanup := complete}} =
                tmux_operation:await(Operation, 900),
            {ok, Completed} = tmux_pane:get(Server, tmux_model:get(id, Job)),
            true = tmux_model:get(dead, Completed),
            0 = tmux_model:get(exit_status, Completed),
            {ok, <<"build complete\n">>} = tmux_pane:capture(
                Completed, #{start => 0, 'end' => 0}),
            {ok, Never} = tmux_command:raw(
                <<"wait-for">>, [<<"not-signalled">>]),
            {ok, Cancelled} = tmux_operation:start(Server, Never, Deadline),
            {ok, _} = tmux_operation:await_started(Cancelled, 900),
            {ok, cancel_requested} = tmux_operation:cancel(Cancelled),
            {error, #{outcome := unknown, cleanup := complete}} =
                tmux_operation:await(Cancelled, 900),
            #{output => <<"build complete\n">>, job_status => 0,
              await_timeout_kept_operation => true,
              cancelled_outcome => unknown}
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

The output is `build complete` followed by a newline, and the exit status is
zero. The zero-duration await proves that abandoning a wait leaves the
operation usable. The separate cancelled wait reports an unknown tmux outcome
and complete client cleanup; cancellation does not undo submitted work.

The example prepares an empty pane, then starts its job with
`tmux_pane:respawn/2`. Respawn keeps the pane ID. Its default launch mode,
`previous`, reuses tmux's saved command; this example supplies new argv instead.
Running panes require explicit `force => true`. Use a job-specific completion
condition and fresh observations to check the result.

Use an empty shell command to prepare a process-free pane with
`tmux_pane:split/2`. Session creation on every supported version, and window
creation before tmux 3.8, can finish that command immediately and remove the
new object. This example uses `/bin/cat` to keep its parent session and window
available across versions.

`await_started/2` returns lifecycle status, including when an operation already
failed or retired. Use `await/2` for its command result. Successful command
results preserve separate stdout/stderr binaries, stdin bytes delivered to the
client pipe, exit status, outcome and cleanup. Validation and wait errors can
contain only a code; do not assume every error contains output or certainty.
The native API defines `t:tmux_operation:completed/0`,
`t:tmux_operation:failure/0` and `t:tmux_operation:state/0`.

Treat a pane's exit_status field independently from its dead flag. tmux exposes
a numeric status after collecting a normal child exit; signal termination has
no numeric value in that field. The captured absence value is none, which does
not mean success. The native pane_dead_signal format can identify a signal
when diagnosing an unexpected exit. This distinction appears in the
[tmux 3.3a status callback](https://github.com/tmux/tmux/blob/3.3a/format.c#L1792)
and the
[tmux 3.8 status callback](https://github.com/tmux/tmux/blob/3.8/format.c#L2288).

## Operation ownership

The process that starts an operation owns it. Other processes can await its
handle without becoming owners. The endpoint confirms a transfer after
monitoring the new owner and releasing the old monitor; the new process does
not perform a handshake. Owner death and cancellation retire queued or
possibly-sent clients; they do not replay mutations.

An `await_timeout` from `tmux_operation:transfer/2` leaves the transfer outcome
uncertain: the endpoint may process the owner change after the caller stops
waiting. Read `tmux_operation:status/1` to establish the current owner before
relying on ownership. The timeout does not prove the old owner still owns the
operation.

Retired results are retained for at most 60 seconds. The endpoint also evicts
the oldest results when retention exceeds 64 results or 4 MiB of stdout/stderr.
Use `tmux_operation:status/1` while a handle is valid, and handle
`operation_expired` after retention. Closing an endpoint retires its library
clients and preserves the tmux server. [Daemon ownership](ownership.md)
explains the separate token used to stop an owned daemon.

Current operations use one-shot clients. Persistent control, grouping and
stream delivery are not yet available; see [support and gaps](compatibility.md).
