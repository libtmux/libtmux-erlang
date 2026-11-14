# Read and change scoped options

Use a local user option to record which workspace created a session. Read it
without inheritance to decide whether the session belongs to that workspace.

- `only_if_unset` refuses an existing local value. It does not compare an
  expected owner and is not a workspace transaction.
- The program also sets and removes a window override, checks that inheritance
  returns, and keeps an empty sparse array entry.
- It opens the supplied endpoint and creates and removes its own session. The
  runner supplies an isolated server.

Run it:

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
            {ok, [<<"build-workspace">>, none]} =
                tmux_option:get_many([Session, Window], Owner, #{}),
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

- A physical window has no universal parent session. Session options need a
  session record; a pane passed to one fails instead of picking a session.
- Built-in names can override tmux's native scope flags. The wrapper checks
  their source metadata before dispatch to prevent that.
- `get/3` reads local values only with `#{}`.
- `#{inherit => true}` follows the table's parents: session defaults, or window
  defaults for a pane. User options follow the same ancestry. Server options
  have no parent. A session table never passes values to a window table.

## Read many rows at once

- `tmux_option:get_many/3` reads one scalar key from one to seven local rows on
  one registered endpoint. Results keep input order, with `none` for absent
  values.
- The program reads the session's ownership and the window's own local table
  together.
- Arrays, indexed entries, command options, global tables and names outside the
  batch grammar use `get/3`.
- A batch is one native command sequence plus the normal identity-preflight
  client, with native ID observations around each row's read.
- Output is capped at 1 MiB of stdout and 64 KiB of stderr, with a 2500 ms
  deadline. A command or decoding failure rejects the whole batch.
- These are interval observations. A queued reference can outlive a removed
  window, and the target checks are not atomic. See
  [ADR 0003](adr-0003-scoped-option-batches.md).

## Preserve absence and bytes

- `none` means the selected local option or array entry is absent.
  `{ok, <<>>}` means a known empty value.
- A whole array returns `{ok, Entries}` with numeric indexes as keys. An empty
  local array returns `{ok, #{}}`.
- Set an entry with `{Name, Index}`. There is no whole-array assignment.
- `unset/2` removes an entry or local option. Removing a local option restores
  inheritance. Unsetting a global built-in resets its tmux default.
- Non-numeric array keys are outside this API. An observed array with such keys
  fails decoding instead of dropping entries.
- Values are NUL-free binaries and may hold any other byte.
- Names are literal. `#{...}` in a user-option name does not expand. Prefixes,
  aliases and bracket syntax are rejected.
- A scalar value goes out without `-F`, but tmux may later interpret a stored
  format or command option. Use this API only with trusted names and values.
- `append` uses tmux's `-a` for the option's type. `only_if_unset` uses `-o`
  and reports an already-set option as an error.
- An empty flag value keeps tmux's toggle behavior. Use `<<"on">>` or
  `<<"off">>` when the state must be predictable.
- A mutation is not retried after a timeout or unknown outcome.

## Discover version support

- The [generated catalogue](options-reference.md) lists canonical names, scopes,
  parser types, arrays and hooks from pinned release commits.
- `tmux_option:describe/2` and `catalogue/1` read it without I/O.
- Built-ins have exact catalogues for every release from 3.3a through 3.8,
  including patch releases. A tracking build or unknown version returns
  `unsupported_option_catalogue`. An unavailable built-in returns
  `unsupported_tmux_option`. User options need no catalogue.
- This API rejects hooks, including names found in the catalogue. Use
  `tmux_hook:get/3` and `tmux_hook:set/3`; the [hook guide](hooks.md) covers
  scope, execution and cleanup.
- Raw commands remain available for deliberate newer-version work.
- A missing target is an operational error, never a missing option.
