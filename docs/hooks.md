# Register a hook and await its effect

Register a split hook, submit a wait without blocking the caller, then split a
pane. The hook writes a session option and signals a unique channel.

- The program checks the option, removes the local hook and verifies cleanup.
- It cancels and awaits its operation in cleanup, even when registration or
  the split fails.
- The runner supplies the daemon.

Compile the project first:

```console
$ mise exec -- rebar3 compile
```

Run the complete program:

```console
$ mise exec -- escript tools/run_examples.escript hooks
```

<!-- example: examples/hook_demo.erl -->

```erlang
-module(hook_demo).
-moduledoc "Acknowledge a registered split hook before reading its effect.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
        {ok, Session} = tmux_session:create(Server,
            Launch#{name => <<"hooks">>}),
        tmux_scope:run_or_error(fun() ->
            {ok, Snapshot} = tmux_server:snapshot(Server),
            [Pane] = tmux_snapshot:panes(Snapshot),
            Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
            Channel = <<"hook-", Suffix/binary>>,
            {ok, Mark} = tmux_command:raw(<<"set-option">>,
                [<<"-t">>, tmux_model:get(id, Session),
                 <<"@last-event">>, <<"split complete">>]),
            {ok, Signal} = tmux_command:wait_for(Channel, signal),
            {ok, Wait} = tmux_command:wait_for(Channel, wait),
            {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
            tmux_scope:run_or_error(fun() ->
                Name = <<"after-split-window">>,
                {ok, _} = tmux_hook:set(Session, {Name, 4}, [Mark, Signal]),
                {ok, _} = tmux_pane:split(Pane, Launch),
                {ok, #{cleanup := complete}} =
                    tmux_operation:await(Operation, 900),
                {ok, <<"split complete">>} =
                    tmux_option:get(Session, <<"@last-event">>, #{}),
                {ok, #{4 := _}} = tmux_hook:get(Session, Name, #{}),
                {ok, _} = tmux_hook:unset(Session, Name),
                none = tmux_hook:get(Session, Name, #{}),
                #{event => <<"split complete">>, hook_acknowledged => true,
                  local_hook_removed => true}
            end, fun() ->
                tmux_scope:run_or_error(fun() ->
                    {ok, _} = tmux_operation:cancel(Operation)
                end, fun() ->
                    case tmux_operation:await(Operation, 900) of
                        {ok, #{cleanup := complete}} -> ok;
                        {error, #{cleanup := complete}} -> ok
                    end
                end), ok
            end)
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

<!-- example-output: hook_demo -->

```json
{
  "event": "split complete",
  "hook_acknowledged": true,
  "local_hook_removed": true
}
```

[Jobs and operations](jobs.md) explains why an await timeout abandons only
that wait.

## Choose the table

- `tmux_hook:set/3` needs a `{Name, Index}` key and validated `tmux_command`
  values. It replaces that indexed entry and keeps the others.
- `append/3` takes tmux's first vacant local index, which can come before
  existing sparse entries. Commands run in index order.
- A body is one command or a nonempty list. Rendering is bounded before
  dispatch.
- Local tables use registered session, physical window or pane rows. Global
  tables use `{session_defaults, Server}` or `{window_defaults, Server}`.
- The [source catalogue](options-reference.md) gives each built-in hook's scope
  and version.
- This API rejects prefixes, aliases, ordinary options and custom event or
  monitor interfaces.

## Read and remove

- `get/3` reads local values by default. `inherit => true` follows parent
  tables.
- An absent local array returns `none`. An empty array returns `{ok, #{}}` and
  masks inheritance.
- `clear/2` leaves that empty override. `unset/2` removes an entry, or restores
  inheritance for the whole array. Unsetting an entry can leave the local array
  empty. A global unset resets the native default.
- Read values are tmux's canonical command-list text, with its own quoting and
  escapes. They are not argument values or the original source. A read never
  runs them.

## Registration, context and completion

- Registration confirms that tmux stored the commands. They still interpret
  their values and formats when they run.
- Native parsing can fail. A failed first indexed write can already leave an
  empty local override.
- There is no rollback and no automatic retry of an uncertain mutation.
- `tmux_hook:run/2` requests native execution in an explicit context: a session
  for its current window and pane, a checked window link for one membership, or
  `{pane, Pane, Link}` for a pane and membership.
- A physical window alone cannot choose a context, so a link keeps the session
  and index when a window is linked more than once.
- Existence and membership checks come before dispatch. If the target vanishes
  afterward, tmux can still fall back to another context. These observations
  are not atomic.
- A command result does not acknowledge background work a hook launched. The
  program waits for its own signal after the option write.
- Clearing or unsetting a hook does not cancel effects tmux already queued.

See [window memberships](graph.md) and [scoped options](options.md) for the
graph and inheritance rules.
