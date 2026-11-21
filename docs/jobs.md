# Wait for a terminal job, then capture its output

See [wait for visible text](#wait-for-visible-text) to observe a running pane.

A successful send does not prove a terminal program processed the input. This
program runs a job that acknowledges terminal parsing, waits for its exit with
`tmux_pane:wait_exit/2` and captures the output.

- The [companion job](../examples/terminal_job.erl) is an escript. It switches
  the terminal to raw mode with `shell:start_interactive({noshell, raw})`,
  writes its result and an ANSI device-status request, and exits only after
  reading tmux's reply, which tmux sends after parsing the output. It writes
  nothing afterward.
- The job needs the Erlang/OTP that runs the example, and nothing else.
- The session and setup window run `cat` while `tmux_pane:split/2` starts the
  job in a separate pane.
- An exit is not an output-drain barrier on tmux 3.3. This protocol covers a
  cooperating job. It cannot reconstruct output that scrolled out of history.
- The program changes two options on its new window only: `remain-on-exit`
  keeps the dead pane addressable, and an empty exit banner keeps the first
  line. `tmux_pane:wait_exit/2` then waits for the job and returns its exit
  status or the signal that ended it.
- There are no sleeps or capture retries.

Run it from the checkout so the job script can be found:

```console
$ mise exec -- escript scripts/check/run_examples.escript job
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
            {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
            {ok, _} = tmux_option:set(
                Window, <<"remain-on-exit-format">>, <<>>),
            Escript = os:find_executable("escript"),
            JobFile = filename:absname("examples/terminal_job.erl"),
            Launch = #{argv => [list_to_binary(Escript),
                list_to_binary(JobFile)]},
            {ok, Job} = tmux_pane:split(Window, #{launch => Launch}),
            {ok, #{exit := {status, 0}, pane := Completed}} =
                tmux_pane:wait_exit(Job, #{deadline_ms => 5000}),
            true = tmux_model:get(dead, Completed),
            {ok, <<"build complete\n">>} = tmux_pane:capture(
                Completed, #{start => 0, 'end' => 0}),
            Deadline = #{deadline_ms => 6000},
            {ok, Never} = tmux_command:raw(
                <<"wait-for">>, [<<"not-signalled">>]),
            {ok, Operation} = tmux_operation:start(Server, Never, Deadline),
            {error, #{code := await_timeout}} =
                tmux_operation:await(Operation, 0),
            {ok, _} = tmux_operation:await_started(Operation, 900),
            {ok, cancel_requested} = tmux_operation:cancel(Operation),
            {error, #{outcome := unknown, cleanup := complete}} =
                tmux_operation:await(Operation, 900),
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
- The second operation waits for a channel that nobody signals. Its
  zero-duration `tmux_operation:await/2` returns `await_timeout` while the
  operation can still run. Call `tmux_operation:status/1` or await it again
  before you submit more work.
- The example cancels the operation, then awaits the result. It reports an
  unknown tmux outcome and complete client cleanup.

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
- A normal exit has a numeric `exit_status`. A death by signal leaves that
  field as `none`.
- `tmux_pane:wait_exit/2` returns `{status, Code}` or `{signal, Signal}`, so a
  death by signal never reads as a missing status. On Linux tmux prints the
  signal as its number.
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

## Wait for visible text

`tmux_pane_text:start/3` samples a live pane on a library-owned server before
it returns. Send input afterward, then call `tmux_pane_text:await/2` to collect
the matching screen. The [workspace example](../examples/readme_demo.erl) runs
this sequence against a pane running `cat`.

<!-- example: examples/readme_demo.erl#watch_text -->

```erlang
        Text = <<"worker ready">>,
        {ok, Wait} = tmux_pane_text:start(Right, Text, #{deadline_ms => 2500}),
        {ok, _} = tmux_pane:send_text(Right, Text),
        {ok, #{screen := Screen}} = tmux_pane_text:await(Wait, 2500),
        ok = tmux_pane_text:release(Wait),
        {_, _} = binary:match(Screen, Text),
```

Use `tmux_pane:wait_for_text/3` to start and await in one call. A match is a
screen observation. Use `tmux_pane:wait_exit/2` for process completion.

An `await_timeout` leaves the observation running. Cancel with
`tmux_pane_text:cancel/1` and await its result to confirm cleanup. Release a
completed handle when you no longer need the result. An expired wait or pane
respawn ends the observation. Start again from a fresh pane record if the
application launches a replacement.
