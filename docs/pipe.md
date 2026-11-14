# Save a job's output and verify the consumer received it

This program opens a pane pipe before releasing the producer. A shell consumer
logs the expected bytes and signals after the write succeeds. The caller checks
the file before stopping the pipe. It never infers delivery from the command.

Compile the project:

```console
$ mise exec -- rebar3 compile
```

Run it on an owned server:

```console
$ mise exec -- escript tools/run_examples.escript pipe
```

<!-- example: examples/pipe_demo.erl -->

```erlang
-module(pipe_demo).
-moduledoc "Save terminal bytes after a consumer acknowledgement.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Directory = <<"/tmp/ltm-pipe-example-", Suffix/binary>>,
    ok = file:make_dir(Directory),
    tmux_scope:run_or_error(fun() ->
        ok = file:change_mode(Directory, 8#700),
        Log = <<Directory/binary, "/job.log">>,
        {ok, Server} = tmux_server:open(
            #{socket_path => Socket, executable => Executable}),
        tmux_scope:run_or_error(fun() ->
            Native = <<(quote(Executable))/binary,
                " -N -S ", (quote(Socket))/binary, " wait-for ">>,
            Start = <<"start-", Suffix/binary>>,
            Done = <<"consumed-", Suffix/binary>>,
            Producer = <<"stty -onlcr && ", Native/binary, Start/binary,
                " && printf 'build complete\\n' && exec /bin/cat">>,
            {ok, Session} = tmux_session:create(Server,
                #{name => <<"pipe-example">>, launch => #{argv =>
                    [<<"/bin/sh">>, <<"-c">>, Producer]}}),
            tmux_scope:run_or_error(fun() ->
                {ok, Snapshot} = tmux_server:snapshot(Server),
                [Pane] = tmux_snapshot:panes(Snapshot),
                Payload = <<"build complete\n">>,
                Size = integer_to_binary(byte_size(Payload)),
                Consumer = <<"/usr/bin/head -c ", Size/binary,
                    " > ", (quote(Log))/binary, " && ", Native/binary,
                    "-S ", Done/binary, " && exec /bin/cat >/dev/null">>,
                {ok, Wait} = tmux_command:wait_for(Done, wait),
                {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
                {ok, _} = tmux_pane:pipe(Pane, #{shell => Consumer}, #{}),
                {ok, Signal} = tmux_command:wait_for(Start, signal),
                {ok, _} = tmux_server:command(Server, Signal, #{}),
                {ok, #{cleanup := complete}} =
                    tmux_operation:await(Operation, 900),
                {ok, Payload} = file:read_file(Log),
                {ok, _} = tmux_pane:stop_pipe(Pane),
                #{log => Payload, bytes_written => byte_size(Payload),
                  consumer_acknowledged => true}
            end, fun() ->
                {ok, _} = tmux_session:kill(Session),
                ok
            end)
        end, fun() ->
            ok = tmux_server:close(Server)
        end)
    end, fun() ->
        ok = file:del_dir_r(Directory)
    end).

quote(Value) ->
    Escaped = binary:replace(Value, <<"'">>, <<"'\\''">>, [global]),
    <<"'", Escaped/binary, "'">>.
```

<!-- example-output: pipe_demo -->

```json
{
  "log": "build complete\n",
  "bytes_written": 15,
  "consumer_acknowledged": true
}
```

- The program uses the Linux utilities `stty`, `/usr/bin/head` and `/bin/cat`.
- It turns off newline translation on the producer's terminal, so the log holds
  LF bytes.
- It removes the temporary log after checking it.

## Choose direction and replacement

- `tmux_pane:pipe/3` takes an explicit shell-command map and a registered
  physical pane. It escapes hash and strftime directives before tmux expands
  the text.
- The shell still interprets the command. The program's `quote/1` handles
  values it inserts into shell code. This operation takes shell code, not
  executable argv.
- `tmux_command:literal_format/2` documents the encoding limits. A command with
  percent signs above tmux's 8191-byte time-format limit returns
  `format_limit` before dispatch, so an existing pipe survives a replacement
  that cannot be represented.

| Direction | Connection |
| --- | --- |
| `output` (default) | Pane PTY output to child stdin |
| `input` | Child stdout to pane input |
| `both` | Both connections |

- Terminal modes affect these bytes.
- This is not rendered screen capture and not a replay of earlier history. It
  is not an Erlang subscription with library flow control.
- Child stderr is discarded. Unused directions go to the null device.
- The API does not copy the pane's working directory or environment into the
  child.
- Starting a pipe normally replaces an existing one. `toggle => true` maps to
  native `-o`: an open pipe closes without starting another, and a closed pipe
  opens. It does not keep an open pipe.

## Tell the pipe from its process

- A successful action proves command completion. It does not prove the shell
  ran, the consumer was ready, bytes arrived or the process exited. The program
  watches the consumer's own file write.
- `tmux_pane:stop_pipe/1` closes the native connection and can discard pending
  bytes. Wait for the consumer's acknowledgement first when delivery matters.
- Closing does not kill or wait for a shell process. A consumer that does not
  finish at EOF needs application-level coordination.
- `tmux_server:close/1` leaves the borrowed pane and its tmux-owned pipe alone.

See [jobs and operations](jobs.md) for library-owned command clients and
[configuration and signals](configuration.md) for native wait channels.
