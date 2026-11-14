# Preserve byte buffers and paste deliberately

Store a binary artifact without a shell, a terminal renderer or Unicode
conversion. Loading uses tmux client stdin. Showing a buffer reads its exact
bytes, including NUL, invalid UTF-8 and protocol-like lines.

Run this program against the runner's isolated server:

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
    tmux_scope:run_or_error(fun() ->
        tmux_scope:run_or_error(fun() ->
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
        end, fun() ->
            case tmux_buffer:delete(Server, Name) of
                {ok, _} -> ok;
                {error, #{code := buffer_not_found}} -> ok;
                Failure -> error({buffer_cleanup_failed, Failure})
            end,
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

<!-- example-output: buffer_demo -->

```json
{
  "byte_count": 21,
  "exact_round_trip": true,
  "empty_load_kept_bytes": true
}
```

The program uses a unique buffer name and deletes the buffer in cleanup.

## Choose a name or the newest buffer

- `tmux_buffer:load/3` takes a binary name or `automatic`, which lets tmux pick
  one.
- `show/2`, `delete/2` and `paste/3` take an observed binary name or `latest`.
- `list/1` returns metadata maps, newest first, with name, size in bytes and
  Unix creation time. It loads no payloads.
- Renaming keeps the order. Loading replacement data inserts a new buffer.
- Names are NUL-free bytes. tmux 3.7 and newer clean names themselves, which
  can reject controls and escape backslashes. Later calls need the stored name
  from `list/1`.
- The list codec keeps embedded delimiters, newlines and invalid UTF-8 where a
  release allows those names. It never treats a newline in a name as a row
  boundary.

## Know the version differences

- An empty load is a native no-op. It creates no buffer and does not truncate
  an existing one. Delete a buffer to remove it.
- Renaming onto an occupied name is refused on tmux 3.3 and 3.3a. From 3.4 it
  replaces. Identical rename inputs fail before dispatch, because some old
  versions handle them unsafely.
- On 3.3 and 3.3a, a native delete or rename of a missing name falls back to
  the newest buffer. These APIs first check that the name exists, with no
  output allowance, and return `buffer_not_found` if not. The check keeps no
  payload and ignores list bounds.
- That check is not atomic. A concurrent removal after it can still trigger the
  native fallback. Serialize outside changes or use tmux 3.4 or newer.
- Buffer names are neither stable identities nor transactional.

## Paste bytes into a registered pane

- `tmux_buffer:paste/3` takes a registered pane, a buffer name or `latest`, and
  an options map.
- Defaults preserve bytes: LF separators, no sanitizing, no bracketing, no
  deletion.
- `separator` replaces each LF with a NUL-free byte string. It is passed
  literally, with no format expansion.
- `sanitize => true` needs tmux 3.7 or newer. Older releases return
  `unsupported_capability` before dispatch. The raw path uses `-S` on newer
  releases.
- `bracketed => true` adds markers only when the target enabled bracketed
  paste.
- `delete => true` removes the buffer after the native paste, including when
  native input-off handling discards the input.
- A completed paste is a tmux command result. It does not prove a child consumed
  the input. See the [job guide](jobs.md) for completion signals and
  ownership.

## Bound reads and keep errors

- Load input shares the endpoint's 256 KiB command admission budget with argv.
- `show/3` takes `max_bytes` from 0 through 1 MiB and `deadline_ms` from 1
  through 600000. Defaults are 1 MiB and 2500 ms.
- Overflow returns `output_limit` with partial command evidence. A truncated
  buffer is never returned as success.
- Lists are bounded to 4096 rows and 1 MiB of encoded output.
- Missing buffers, gone panes and closed endpoints stay distinct errors.
- A timeout does not undo a completed load or paste. Mutations are not retried.
- `tmux_buffer:capabilities/1` describes source-defined behavior without I/O.
  The [support page](compatibility.md) separates that metadata from what is
  tested.
