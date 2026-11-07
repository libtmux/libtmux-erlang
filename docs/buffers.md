# Preserve byte buffers and paste deliberately

Store a binary artifact without sending it through a shell, terminal renderer
or Unicode conversion. Loading uses tmux client stdin; showing a buffer reads
its exact bytes, including NUL, invalid UTF-8 and protocol-like lines.

Run this complete program against the runner's isolated server:

```console
$ mise exec -- escript tools/run_examples.escript buffers
```

<!-- example: examples/buffer_demo.erl -->

```erlang
-module(buffer_demo).
-moduledoc "Store a binary artifact without terminal or text conversion.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    Name = <<"libtmux-example-",
        (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>,
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    try
        try
            Bytes = <<0, 255, "build\n%end 1 2 3\n\\r">>,
            {ok, _} = tmux_buffer:load(Server, Name, Bytes),
            {ok, Bytes} = tmux_buffer:show(Server, Name),
            {ok, [#{name := Name, size := Size} | _]} =
                tmux_buffer:list(Server),
            Size = byte_size(Bytes),
            {ok, _} = tmux_buffer:load(Server, Name, <<>>),
            {ok, Bytes} = tmux_buffer:show(Server, Name),
            #{byte_count => Size, exact_round_trip => true,
              empty_load_kept_bytes => true}
        after
            case tmux_buffer:delete(Server, Name) of
                {ok, _} -> ok;
                {error, #{code := buffer_not_found}} -> ok;
                Failure -> error({buffer_cleanup_failed, Failure})
            end
        end
    after
        ok = tmux_server:close(Server)
    end.
```

<!-- example-output: buffer_demo -->

```json
{
  "byte_count": 21,
  "exact_round_trip": true,
  "empty_load_kept_bytes": true
}
```

The program uses a unique name and removes its buffer in cleanup. The runner
also retires the owned server; the archive check repeats this program outside
the source checkout against the installed core application.

## Choose a name or the newest buffer

`tmux_buffer:load/3` accepts a binary name or `automatic`, which lets tmux
allocate a name. `show/2`, `delete/2` and `paste/3` accept an observed binary
name or `latest`. `list/1` returns ordinary metadata maps in tmux's newest-first
insertion order, with name, size in bytes and Unix creation time. It does not
load payloads. Renaming keeps the order; loading replacement data inserts a
new buffer.

Names are NUL-free bytes. tmux 3.7+ applies its own name cleaning, which can
reject controls and escape backslashes. Subsequent calls need the actual
stored name from `list/1`. The list codec preserves embedded delimiters,
newlines and invalid UTF-8 on releases that allow those names. It never uses
a newline inside a name as a row boundary.

Empty load input is a native no-op: it neither creates a buffer nor truncates
an existing one. Delete explicitly when the buffer should disappear. A named
rename refuses an occupied destination on tmux 3.3/3.3a; 3.4+ replaces it.
Identical rename inputs fail before dispatch because some legacy versions
have unsafe handling of that case.

On 3.3/3.3a, native named delete/rename falls back to the newest buffer when
the requested name is absent. These APIs first perform a targeted existence
read with zero output allowance and return `buffer_not_found` for a missing
name. The read retains no payload and is independent of list bounds.
That preflight is not atomic:
concurrent removal after the check can still trigger the native fallback.
Serialize external changes or use tmux 3.4+ when that race is unacceptable.
Buffer names do not provide stable object identities or transactional updates.

## Paste bytes into a registered pane

`tmux_buffer:paste/3` takes a registered pane, a buffer name or `latest`, and
an options map. Defaults preserve bytes: LF separators, no sanitization, no
bracketing and no deletion. Set `separator` to replace each LF with a chosen
NUL-free byte string. It is passed literally, without format expansion.

`sanitize => true` requires tmux 3.7+; older releases return
`unsupported_capability` before dispatch. The default raw path uses `-S` on
newer releases. `bracketed => true` adds markers only when the target has
enabled bracketed paste. `delete => true` removes the buffer after the native
paste call, including cases where native input-off handling discards input.

A completed paste is a tmux command result, not proof that a child consumed
input. The integration test uses a raw terminal receiver and a separate socket
acknowledgment to verify all 256 byte values and custom separators. The
[job guide](jobs.md) explains completion signals and operation ownership.

## Bound reads and preserve errors

Load input shares the endpoint's 256 KiB command admission budget with argv.
`show/3` accepts `max_bytes` from 0 through 1 MiB and `deadline_ms` from 1 through
600000. Defaults are 1 MiB and 2500 ms. Overflow returns `output_limit` with
partial command evidence; it never returns a successful truncated buffer.
Lists are bounded to 4096 rows and 1 MiB of encoded output.

Missing buffers, gone panes and closed endpoints remain distinct errors.
Timeouts do not undo a completed load or paste, and mutations are not retried.
`tmux_buffer:capabilities/1` describes source-defined behavior without I/O;
the [support page](compatibility.md) separates that metadata from qualification.
