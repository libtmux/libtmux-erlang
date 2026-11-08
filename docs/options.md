# Read and change scoped options

Use a local user option to record which workspace created a session. Read it
without inheritance when deciding whether the session belongs to that workspace.
`only_if_unset` refuses an existing local value; it does not compare an expected
owner or provide a workspace transaction.

The complete example also sets and removes a window override, checks that the
inherited value is restored, and preserves an empty sparse array entry. It
opens the supplied endpoint and creates/removes its own session. The repository
runner supplies an isolated server and verifies cleanup:

```console
$ mise exec -- escript tools/run_examples.escript options
```

<!-- example: examples/options_demo.erl -->

```erlang
-module(options_demo).
-moduledoc "Use local options to mark workspace ownership without inheritance.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"options">>, launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            Owner = <<"@libtmux-owner">>,
            none = tmux_option:get(Session, Owner, #{}),
            {ok, _} = tmux_option:set(Session, Owner, <<"build-workspace">>,
                #{only_if_unset => true}),
            {ok, <<"build-workspace">>} = tmux_option:get(Session, Owner, #{}),
            {ok, Window} = tmux_window:create(Session,
                #{launch => #{argv => [<<"/bin/cat">>]}}),
            none = tmux_option:get(Window, <<"remain-on-exit">>, #{}),
            {ok, Effective} = tmux_option:get(Window, <<"remain-on-exit">>,
                #{inherit => true}),
            {ok, _} = tmux_option:set(Window, <<"remain-on-exit">>, <<"on">>),
            {ok, <<"on">>} = tmux_option:get(Window, <<"remain-on-exit">>, #{}),
            {ok, _} = tmux_option:unset(Window, <<"remain-on-exit">>),
            none = tmux_option:get(Window, <<"remain-on-exit">>, #{}),
            {ok, Effective} = tmux_option:get(Window, <<"remain-on-exit">>,
                #{inherit => true}),
            Env = <<"update-environment">>,
            {ok, _} = tmux_option:set(Session, {Env, 7}, <<>>),
            {ok, #{7 := <<>>}} = tmux_option:get(Session, Env, #{}),
            none = tmux_option:get(Session, {Env, 8}, #{}),
            #{owner => <<"build-workspace">>, restored_inheritance => true,
              empty_entry_preserved => true, missing_entry => true}
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

<!-- example-output: options_demo -->

```json
{
  "owner": "build-workspace",
  "restored_inheritance": true,
  "empty_entry_preserved": true,
  "missing_entry": true
}
```

## Select the table explicitly

| Scope argument | Table |
| --- | --- |
| Registered session record | Local session options |
| Registered physical window record | Local window options, shared by its memberships |
| Registered pane record | Local pane options |
| `{server, Server}` | Server-wide options |
| `{session_defaults, Server}` | Global session defaults |
| `{window_defaults, Server}` | Global window defaults |

A physical window has no universal parent session. Session options require a
session record; passing a pane to a session option fails rather than choosing
an incidental session. Built-in names can override tmux's native scope flags;
the wrapper checks their source metadata before dispatch to prevent that.

`get/3` uses local-only reads with `#{}`. `#{inherit => true}` follows the
selected table's parents: session defaults, or window/window defaults for a
pane. User options follow the same table ancestry. Server options have no
parent. There is no inheritance from a session table to a window table.

## Preserve absence and bytes

`none` means the selected local option or requested array entry is absent.
`{ok, <<>>}` means a known empty value. A whole array returns `{ok, Entries}`
with numeric indexes as map keys; an empty local array returns `{ok, #{}}`.
An unloaded graph field is unrelated to these live reads.

Set array entries with `{Name, Index}`. The API deliberately avoids whole-array
assignment and its separator grammar. `unset/2` removes an entry or local option;
removing a local option restores inheritance. Unsetting a global built-in resets
its tmux default. Non-numeric array keys are outside this API; an observed array
with such keys fails decoding instead of silently dropping entries.

Values are NUL-free binaries, including arbitrary bytes. Names are literal;
`#{...}` in a user-option name does not expand. Prefixes, aliases and bracket
syntax in names are rejected. A scalar value is passed without `-F`, although
tmux may interpret a stored format or executable option later. Use this API
only with trusted option names and values; it is not an external write policy.

`append` uses tmux's `-a` behavior for the selected type. `only_if_unset` uses
`-o` and reports already-set as an error. Empty flag values retain tmux's toggle
behavior; use explicit `<<"on">>` or `<<"off">>` when state must be predictable.
Mutations are not retried after a timeout or unknown outcome.

## Discover version support

The [generated catalogue](options-reference.md) lists canonical names, scopes,
parser types, arrays and hooks from the exact source commits used by CI.
`tmux_option:describe/2` and `catalogue/1` read that metadata without I/O.
Built-ins require an exact catalogue version: 3.3, 3.3a, 3.4, 3.5a, 3.6b, 3.7c
or 3.8. Tracking builds and other versions return
`unsupported_option_catalogue`; unavailable built-ins return
`unsupported_tmux_option`. User options do not depend on a built-in catalogue.

Hooks are executable commands and are rejected by this API, including hook
names discovered in the catalogue. The [job example](jobs.md) currently uses an
explicit raw `set-hook` command. A typed hook API remains implementation work.
Raw commands are also available for deliberate newer-version integration.
A missing target remains an operational error, never a missing option.
