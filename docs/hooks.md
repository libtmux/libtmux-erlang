# Register a hook and await its effect

Register a split hook, submit a wait without blocking the Erlang caller, then
split a pane. The hook writes a session option and signals the unique channel.
The program checks that effect, removes the local hook and verifies cleanup.
The runner owns the daemon and checks that its sessions and processes exit.
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
    try
        Launch = #{launch => #{argv => [<<"/bin/cat">>]}},
        {ok, Session} = tmux_session:create(Server,
            Launch#{name => <<"hooks">>}),
        try
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
            try
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
            after
                {ok, _} = tmux_operation:cancel(Operation),
                case tmux_operation:await(Operation, 900) of
                    {ok, #{cleanup := complete}} -> ok;
                    {error, #{cleanup := complete}} -> ok
                end
            end
        after
            {ok, _} = tmux_session:kill(Session)
        end
    after
        ok = tmux_server:close(Server)
    end.
```

<!-- example-output: hook_demo -->

```json
{
  "event": "split complete",
  "hook_acknowledged": true,
  "local_hook_removed": true
}
```

The archive check repeats this program using the installed core package.
[Jobs and operations](jobs.md) explains why an await timeout abandons only
that wait. The program cancels and awaits its operation during cleanup even
if registration or the split fails.

## Choose the table explicitly

`tmux_hook:set/3` requires a `{Name, Index}` key and validated
`tmux_command` values. It replaces that indexed entry while preserving other
entries. `append/3` chooses tmux's first vacant local index, which can precede
existing sparse entries. Commands run in index order. Bodies can be one
command or a nonempty list; rendering is bounded before dispatch.

Local tables use registered session, physical window or pane rows. Global
tables use `{session_defaults, Server}` or `{window_defaults, Server}`.
The [source catalogue](options-reference.md) defines each builtin hook's
permitted scope and version. Prefixes, aliases, ordinary options and custom
event/monitor interfaces are rejected by this API.

`get/3` reads local values by default. `inherit => true` follows parent tables.
An absent local array returns `none`; an empty array returns `{ok, #{}}` and
masks inheritance. `clear/2` leaves that empty override. `unset/2` removes an
entry or restores inheritance for the whole array. Unsetting an entry can
leave its local array empty. Global unset resets the native default.

Read values are tmux's canonical command-list text, including its own quoting
and escapes. They are not individual argument values or the original source
text. A read never executes them.

## Separate registration, context and completion

Registration confirms that tmux stored the commands. Those commands still
interpret their values and formats when they run. Native parsing can fail;
a failed first indexed write can already leave an empty local override.
There is no rollback or automatic retry of an uncertain mutation.

`tmux_hook:run/2` requests native execution in an explicit context. Use a
session for its current window/pane, a checked window link for one membership,
or `{pane, Pane, Link}` for that pane and membership. This preserves the
chosen session and index when a physical window is linked more than once. A
physical window alone cannot choose that execution context. Existence and
membership checks precede dispatch. If the target disappears after preflight,
tmux can still fall back to another context. These separate observations do
not provide atomic compare-and-act.

A native command result does not acknowledge background work launched by a
hook. The program waits for its own signal after the option write. Clearing
or unsetting a hook does not cancel effects tmux has already queued.
[Window memberships](graph.md) and [scoped options](options.md) explain the
related graph and inheritance rules.
