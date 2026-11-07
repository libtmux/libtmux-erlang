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
    try
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"jobs">>, width => 120, height => 30,
              launch => #{argv => [<<"/bin/cat">>]}}),
        try
            {ok, Window} = tmux_window:create(Session,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            Target = [<<"-w">>, <<"-t">>, tmux_model:get(id, Window)],
            Deadline = #{deadline_ms => 2000},
            {ok, Keep} = tmux_command:raw(<<"set-option">>,
                Target ++ [<<"remain-on-exit">>, <<"on">>]),
            {ok, _} = tmux_server:command(Server, Keep, #{}),
            {ok, Banner} = tmux_command:raw(<<"set-option">>,
                Target ++ [<<"remain-on-exit-format">>, <<>>]),
            {ok, _} = tmux_server:command(Server, Banner, #{}),
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
            {ok, Job} = tmux_pane:split(Window, #{launch => Launch}),
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
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
```

The output is `build complete` followed by a newline, and the exit status is
zero. The zero-duration await proves that abandoning a wait leaves the
operation usable. The separate cancelled wait reports an unknown tmux outcome
and complete client cleanup; cancellation does not undo submitted work.

`await_started/2` returns lifecycle status, including when an operation already
failed or retired. Use `await/2` for its command result. Successful command
results preserve separate stdout/stderr binaries, stdin bytes delivered to the
client pipe, exit status, outcome and cleanup. Validation and wait errors can
contain only a code; do not assume every error contains output or certainty.
The native API defines `t:tmux_operation:completed/0`,
`t:tmux_operation:failure/0` and `t:tmux_operation:state/0`.

## Operation ownership

The process that starts an operation owns it. Other processes can await its
handle without becoming owners. The endpoint confirms a transfer after monitoring the new owner
and releasing the old monitor; the new process does not perform a handshake. Owner death and cancellation retire queued
or possibly-sent clients; they do not replay mutations.

Retired results are retained for at most 60 seconds. The endpoint also evicts
the oldest results when retention exceeds 64 results or 4 MiB of stdout/stderr. Use
`tmux_operation:status/1` while a handle is valid, and handle
`operation_expired` after retention. Closing an endpoint retires its library
clients and preserves the borrowed tmux server.

Current operations use one-shot clients. Persistent control, grouping and
stream delivery are not yet available; see [support and gaps](compatibility.md).
