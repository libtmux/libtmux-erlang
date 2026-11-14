# Wait for a terminal job, then capture its output

A successful send does not prove a terminal program processed the input. This
program runs a job that acknowledges terminal parsing, waits for `pane-died`,
checks the exit status and captures the output.

- The [companion job](../examples/terminal_job.py) writes its result and an
  ANSI device-status request. It exits only after reading tmux's reply, which
  tmux sends after parsing the output. It writes nothing afterward.
- The job needs Python 3.12 or newer. The library does not.
- `pane-died` alone is not an output-drain barrier on tmux 3.3. This protocol
  covers a cooperating job. It cannot reconstruct output that scrolled out of
  history.
- The program changes options and a hook only on its new window:
  `remain-on-exit` keeps the pane addressable, an empty exit banner keeps the
  first line, and the hook signals a tmux `wait-for` channel.
- There are no sleeps or capture retries.

Run it from the checkout so the job script can be found:

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

- The output is `build complete` and a newline. The exit status is zero.
- The zero-duration await shows that abandoning a wait leaves the operation
  usable.
- The separate cancelled wait reports an unknown tmux outcome and complete
  client cleanup. Cancellation does not undo submitted work.

## Start a job in a prepared pane

- The program prepares an empty pane with `tmux_pane:split/2` and an empty
  shell command, then starts the job with `tmux_pane:respawn/2`. Respawn keeps
  the pane ID.
- Respawn's launch mode defaults to `previous`, which reuses tmux's saved
  command. The program passes new argv instead. A running pane needs
  `force => true`.
- Judge the result with a job-specific completion condition and fresh
  observations.
- With an empty shell command, a new session (any version) or window (before
  tmux 3.8) can finish at once and vanish. The program uses `/bin/cat` for its
  session and window to avoid that.

## Read results

- `await_started/2` returns lifecycle status, including for an operation that
  already failed or retired. `await/2` returns the command result.
- A successful result holds separate stdout and stderr binaries, the stdin
  bytes delivered to the client pipe, exit status, outcome and cleanup.
- Validation and wait errors can hold only a code. Do not assume they hold
  output or certainty.
- The native API defines `t:tmux_operation:completed/0`,
  `t:tmux_operation:failure/0` and `t:tmux_operation:state/0`.

## Read a pane's exit status

- `exit_status` and `dead` are separate fields.
- After a normal exit, tmux gives a numeric status. A signal has no number, so
  the captured value is `none`, which does not mean success.
- `pane_dead_signal` names the signal when you diagnose an unexpected exit.
- The distinction comes from the
  [tmux 3.3a status callback](https://github.com/tmux/tmux/blob/3.3a/format.c#L1792)
  and the
  [tmux 3.8 status callback](https://github.com/tmux/tmux/blob/3.8/format.c#L2288).

## Operation ownership

- The process that starts an operation owns it. Other processes can await its
  handle without owning it.
- A transfer completes once the endpoint monitors the new owner and releases
  the old monitor. The new process does no handshake.
- Owner death and cancellation retire queued or possibly-sent clients. They do
  not replay mutations.
- An `await_timeout` from `tmux_operation:transfer/2` leaves the outcome
  uncertain. Read `tmux_operation:status/1` before you rely on ownership.
- Retired results stay for at most 60 seconds. Past 64 results or 4 MiB of
  stdout and stderr, the oldest go first. Handle `operation_expired`.
- Closing an endpoint retires its library clients and preserves the tmux
  server. [Daemon ownership](ownership.md) covers the token that stops an owned
  daemon.
- Operations use one-shot clients. Persistent control, grouping and stream
  delivery are not built; see [support and gaps](compatibility.md).
