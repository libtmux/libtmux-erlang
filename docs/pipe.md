# Save a job's output and verify the consumer received it

This program opens a pane pipe before releasing the producer. A shell consumer
reads the expected bytes into a log and signals completion only after that
write succeeds. The Erlang caller verifies the file contents before stopping
the pipe. It does not infer delivery from pipe creation or command completion.

Compile the project:

```console
$ mise exec -- rebar3 compile
```

Run on an owned server. The runner verifies session and process cleanup:

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
    ok = file:change_mode(Directory, 8#700),
    try
        Log = <<Directory/binary, "/job.log">>,
        {ok, Server} = tmux_server:open(
            #{socket_path => Socket, executable => Executable}),
        try
            Native = <<(quote(Executable))/binary,
                " -N -S ", (quote(Socket))/binary, " wait-for ">>,
            Start = <<"start-", Suffix/binary>>,
            Done = <<"consumed-", Suffix/binary>>,
            Producer = <<"stty -onlcr && ", Native/binary, Start/binary,
                " && printf 'build complete\\n' && exec /bin/cat">>,
            {ok, Session} = tmux_session:create(Server,
                #{name => <<"pipe-example">>, launch => #{argv =>
                    [<<"/bin/sh">>, <<"-c">>, Producer]}}),
            try
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
            after
                {ok, _} = tmux_session:kill(Session)
            end
        after
            ok = tmux_server:close(Server)
        end
    after
        ok = file:del_dir_r(Directory)
    end.

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

The example uses Linux shell utilities `stty`, `/usr/bin/head` and `/bin/cat`.
It disables newline translation on the producer's terminal, so the expected
log contains LF bytes. The temporary log is removed after verification. The
archive check repeats the program with the installed core package.

## Choose direction and replacement behavior

`tmux_pane:pipe/3` requires an explicit shell-command map and a registered
physical pane. It escapes hash and strftime directives before tmux expands
that text. The shell still interprets the command; the example's `quote/1`
handles values inserted into its shell code. This native operation takes shell
code rather than executable argv.

`tmux_command:literal_format/2` documents the encoding limits. Percent-bearing
commands above tmux's 8191-byte intermediate time-format limit return
`format_limit` before dispatch. That check preserves an existing pipe when a
replacement cannot be represented safely.

| Direction | Connection |
| --- | --- |
| `output` (default) | Pane PTY output to child stdin |
| `input` | Child stdout to pane input |
| `both` | Both connections |

Terminal modes affect these bytes. This is neither rendered screen capture
nor a replay of prior terminal history. It is not an Erlang subscription with
library flow control. Child stderr is discarded; unused directions use tmux's
native null-device routing. The API does not copy the pane's cwd or environment
into the child process.

Starting a pipe normally replaces an existing one. `toggle => true` maps to
native `-o`: an open pipe is closed without starting another, while a closed
pipe is opened. It does not mean preserve an already open pipe.

## Distinguish the pipe from its process

A successful action proves command completion, not shell execution success,
consumer readiness, delivered bytes or process exit. The example observes the
consumer's actual file write. Native integration tests independently verify
all 256 byte values in both directions, literal hash/percent shell text,
replacement, toggle and process retirement.

`tmux_pane:stop_pipe/1` closes the native connection and can discard pending
bytes. Wait for the consumer's acknowledgement before closing when delivery
matters. Closing does not kill or wait for an arbitrary shell process; a
consumer that does not finish on EOF needs application-level coordination.
`tmux_server:close/1` preserves the borrowed pane and its tmux-owned pipe.
[Jobs and operations](jobs.md) covers library-owned command clients;
[configuration and signals](configuration.md) explains native wait channels.
