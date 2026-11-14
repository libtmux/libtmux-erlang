# Install application keybindings

Use a separate key table for application bindings. This program binds `z` to
zoom with a status message and `s` to show the workspace name, reads the native
listing and removes its table. It attaches no client and presses no key.

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
    tmux_scope:run_or_error(fun() ->
        Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
        Table = <<"workspace-", Suffix/binary>>,
        {ok, Zoom} = tmux_command:raw(<<"resize-pane">>, [<<"-Z">>]),
        {ok, Status} = tmux_command:raw(<<"display-message">>,
            [<<"Workspace: #{session_name}">>]),
        {ok, _} = tmux_key:bind(Server, <<"z">>, [Zoom, Status],
            #{table => Table, note => <<"Zoom the current workspace pane">>}),
        tmux_scope:run_or_error(fun() ->
            {ok, _} = tmux_key:bind(Server, <<"s">>, Status,
                #{table => Table, note => <<"Show the workspace name">>}),
            {ok, Listing} = tmux_key:listing(Server, #{table => Table}),
            true = binary:match(Listing, <<"resize-pane">>) =/= nomatch,
            true = binary:match(Listing, <<"display-message">>) =/= nomatch,
            #{bindings => 2, native_listing => true,
              execution => <<"requires a client key press">>}
        end, fun() ->
            {ok, _} = tmux_key:clear_table(Server, Table),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

<!-- example-output: key_demo -->

```json
{
  "bindings": 2,
  "native_listing": true,
  "execution": "requires a client key press"
}
```

## Register a binding

- `tmux_key:bind/3` registers in the native prefix table.
- `tmux_key:bind/4` takes an explicit `table`, a Boolean `repeat` and a byte
  `note`.
- A body is one command or a flat nonempty list, within the limits of
  `tmux_command:to_config/1`: 256 commands and 32 KiB of rendered text.
- tmux parses the body before it replaces an existing binding. Replacement
  resets the old commands, repeat flag and note.
- Tables belong to the server. Creating one selects it for no client. Choose a
  session's default with the `key-table` option in [`tmux_option`](options.md).
  Native prefix, repeat and table-switching rules still apply.
- Registration quotes arguments for the stored command parser. A command can
  still expand formats when a client runs it: the program's `#{session_name}`
  expands then. See [configuration](configuration.md) before you store nested
  command strings or shell commands.
- An accepted registration does not prove future execution. When you need proof,
  arrange a completion signal as in the [hook example](hooks.md).

## Read listings and remove bindings

- `tmux_key:listing/1` and `listing/2` return native bytes unchanged. Options
  can restrict `table` and `key`.
- The layout follows the daemon release. It is a display view: keep the
  original command values to reinstall bindings.
- tmux 3.4 may escape dollar signs in this view.
- On tmux 3.7c, one matching entry can take the native status-message path and
  give empty stdout when no client is attached. Empty output does not prove a
  binding is absent. The program lists several bindings to avoid that path.
- tmux 3.3 has no custom listing format option. Newer-server options stay
  available through `tmux_command:raw/2`.
- `tmux_key:unbind/2` and `unbind/3` remove one binding. An absent key in an
  existing table is a native no-op. Removing the last custom binding can remove
  its table.
- A missing named table and an invalid key name stay errors.
- `tmux_key:clear_table/2` needs an explicit name and removes the whole table.
  It can affect attached clients. It does not restore default bindings or
  cancel commands a client already queued.
- Calls use the registered endpoint identity and keep backend diagnostics. They
  never start a missing server or retry an uncertain mutation.
- The [API browser](api.md) documents input bounds, results and errors.
