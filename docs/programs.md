# Run a program in a private terminal

Use `tmux_program` to own the application, terminal and tmux server together.
Managed programs require tmux 3.8's history counters. Use
`tmux_capability:describe(program_history)` to inspect the minimum and
`tmux_capability:decision/2` with a known daemon version.

## Run to completion

Pass the absolute path to tmux as `Executable`. The first entry in `Argv`
is the absolute application path. tmux receives the remaining binary arguments
literally, including empty arguments and the text below.

<!-- example: examples/program_demo.erl#run -->

```erlang
    Text = <<"build; #{pane_id}">>,
    Argv = [<<"/usr/bin/printf">>, <<"%s\n">>, Text],
    Result = tmux_program:run(Executable, Argv, #{height => 4}),
```

The rendered screen starts with `build; #{pane_id}`. The result records
`{status, 0}` and confirmed cleanup. A nonzero exit can also have a complete
capture. A signal is returned as `{signal, Signal}`.

From the checkout, compile the core and run [the example](../examples/program_demo.erl).

```console
$ rebar3 compile
```

```console
$ escript scripts/check/run_examples.escript program
```

On tmux 3.8 the example checks the literal line, the interactive reply
`heard build` and cleanup after stop. On earlier supported releases it checks
`unsupported_capability` with the found and required versions.

## Send input and stop

`tmux_program:start/3` returns a handle while the program starts. Wait for
the launch gate before sending input. The example's line reader uses
`/bin/sh -c` explicitly and reads one line in the terminal's default mode.

<!-- example: examples/program_demo.erl#input -->

```erlang
        {ok, #{state := released}} = tmux_program:await_started(Program, 900),
        {ok, #{bytes := 6}} = tmux_program:send_text(Program, <<"build\n">>),
        {ok, #{exit := {status, 0}, screen := Screen, cleanup := complete}} =
            tmux_program:await(Program, 900),
```

The launch gate reports release to the terminal. The application controls its
input mode and readiness. The final result verifies the exit and launch
report. One input request can occupy the slot at a time, up to 2,000 bytes.
Treat `input_unconfirmed` as an unknown delivery outcome before retrying.

An await timeout ends that wait. Other waits and the run keep their own
deadlines. To stop a running program, request stop and collect the receipt.

<!-- example: examples/program_demo.erl#stop -->

```erlang
        {ok, #{state := released}} = tmux_program:await_started(Program, 900),
        {error, #{code := await_timeout}} = tmux_program:await(Program, 0),
        {ok, stop_requested} = tmux_program:stop(Program),
        {error, #{code := program_stopped, cleanup := complete}} =
            tmux_program:await(Program, 900),
```

Call `tmux_program:release/1` after collection. The example uses an `after`
block to request stop, collect and release if work fails. Exiting the
starting Erlang process requests stop as well.

## Capture and cleanup

The capture contains terminal cells and retained scrollback. Standard output
and standard error share the PTY. Wrapping, erasure and overwrites affect
what the terminal retains. `history.collected` counts history lines tmux
discarded. `pending_bytes` counts bytes left in incomplete escape sequences.
Read the history generation alongside its counters.

| Option | Default |
| --- | --- |
| `cwd` | Current working directory |
| `env` | No overrides |
| `width` and `height` | 80 columns and 24 rows |
| `history_lines` | 1,000 lines |
| `max_bytes` | 65,536 rendered bytes |
| `deadline_ms` | 30,000 ms for setup, execution and capture |

Limit `width * (height + history_lines)` to 1,048,576 cells. Pending
bytes have a separate limit of up to 4,096 bytes, also capped
by `max_bytes`. An `output_limit` result carries the verified exit, byte
limit and history. Its `stream` is `stdout` for rendered capture or `pending`
for incomplete terminal input.

Eight slots per Erlang node cover active runs, completed results and native
cleanup awaiting confirmation. Completed results expire after 60 seconds.
Free a result sooner with `release/1`.

On `program_cleanup_incomplete`, read `primary` and `causes`. When
`resources.ownership` is present, pass it to `tmux_server:stop_owned/1` to
retry daemon retirement. A slot remains reserved until cleanup is confirmed.

Cleanup covers a finite tree of owned processes. If the helper receives
`SIGKILL` or the program keeps forking during teardown, cleanup can remain
incomplete. See [daemon ownership](ownership.md) and the
[helper protocol](../apps/libtmux_erlang/c_src/README.md).

Each program runs with the caller's OS permissions. Manage its files and work
delegated to external services through their own lifecycles.

For a job in an existing pane, see [wait for a terminal job](jobs.md).
