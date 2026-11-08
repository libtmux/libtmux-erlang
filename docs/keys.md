# Install application keybindings

Use a separate key table when an application needs its own bindings. This
program binds `z` to zoom and show a status message, and `s` to show the
workspace name. It reads the native listing and removes its table. It does not
attach a client or press a key.

From the checkout, after [building the core](installation.md), run:

```console
$ mise exec -- escript tools/run_examples.escript keys
```

<!-- example: examples/key_demo.erl -->

```erlang
-module(key_demo).
-moduledoc "Install and remove an application-owned key table.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    try
        Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
        Table = <<"workspace-", Suffix/binary>>,
        {ok, Zoom} = tmux_command:raw(<<"resize-pane">>, [<<"-Z">>]),
        {ok, Status} = tmux_command:raw(<<"display-message">>,
            [<<"Workspace: #{session_name}">>]),
        {ok, _} = tmux_key:bind(Server, <<"z">>, [Zoom, Status],
            #{table => Table, note => <<"Zoom the current workspace pane">>}),
        try
            {ok, _} = tmux_key:bind(Server, <<"s">>, Status,
                #{table => Table, note => <<"Show the workspace name">>}),
            {ok, Listing} = tmux_key:listing(Server, #{table => Table}),
            true = binary:match(Listing, <<"resize-pane">>) =/= nomatch,
            true = binary:match(Listing, <<"display-message">>) =/= nomatch,
            #{bindings => 2, native_listing => true,
              execution => <<"requires a client key press">>}
        after
            {ok, _} = tmux_key:clear_table(Server, Table)
        end
    after
        ok = tmux_server:close(Server)
    end.
```

<!-- example-output: key_demo -->

```json
{
  "bindings": 2,
  "native_listing": true,
  "execution": "requires a client key press"
}
```

The runner owns an isolated server. The program uses the public core API, and
the installed-archive check repeats it outside the source checkout. Common
Test separately drives a real terminal client's key input, verifies the bound
command's bytes and acknowledgement, and proves client retirement on success,
failure and cancellation.

## Registration and execution are separate

`tmux_key:bind/3` registers in the native prefix table.
`tmux_key:bind/4` accepts an explicit `table`, Boolean `repeat` and byte `note`.
It accepts one command or a flat nonempty command list, with the bounds of
`tmux_command:to_config/1`: at most 256 commands and 32 KiB of rendered text.
tmux parses the body before replacing an existing binding. Replacement resets
the previous commands, repeat flag and note.

Tables belong to the server. Creating one does not select it for any client.
Choose a session's default through the `key-table` option in
[`tmux_option`](options.md); native prefix, repeat and client table-switching
rules still apply. The example leaves client selection to the application.

Registration quotes arguments for the stored command parser. A command can
still interpret formats when a client executes it: the example's
`#{session_name}` is evaluated then. See
[configuration boundaries](configuration.md) before storing nested command
strings or explicit shell commands. An accepted registration does not prove
future execution; arrange a completion signal when an application needs one,
as in the [hook example](hooks.md).

## Read listings and remove owned bindings

`tmux_key:listing/1` and `tmux_key:listing/2` return native bytes unchanged.
Options can restrict `table` and `key`. Spacing, quoting and included metadata
follow the daemon release. This is a presentation view: retain original command
values for reinstalling bindings. tmux 3.4 may escape dollar signs in this
view. On tmux 3.7c, a single matching entry can go to the native status-message
path and produce empty stdout when no target client is attached. Empty output
does not prove a binding is absent. The example lists multiple bindings to
avoid that path. The tmux 3.3 baseline has no custom listing format option.
Explicit newer-server options remain available through
`tmux_command:raw/2`.

`tmux_key:unbind/2` and `tmux_key:unbind/3` remove one binding; an absent key in
an existing table is a native no-op. Removing the final custom binding may
remove its table.
Missing explicitly named tables and invalid native key names remain errors.
`tmux_key:clear_table/2` requires an explicit name and removes the entire
table. It can affect attached clients and does not restore default bindings
or cancel commands already queued by a client.

Calls use the registered endpoint identity and preserve backend diagnostics.
They do not start a missing server or retry uncertain mutations. The native
[`tmux_key` API browser](api.md) documents input bounds, results and errors.
