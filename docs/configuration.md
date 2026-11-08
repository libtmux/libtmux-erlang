# Apply configuration and await its completion signal

Submit a wait without blocking the Erlang caller, then load configuration that
sets an owned session option and signals the channel. The signal works whether
the waiter arrives before or after it. The program verifies the stored value
and checks that parse-only loading leaves it unchanged. The runner owns the
daemon and verifies session and process cleanup. Compile the project first:

```console
$ mise exec -- rebar3 compile
```

Run the complete program:

```console
$ mise exec -- escript tools/run_examples.escript config
```

<!-- example: examples/config_demo.erl -->

```erlang
-module(config_demo).
-moduledoc "Apply session configuration and wait for its explicit signal.".
-export([run/2]).

-spec run(binary(), binary()) -> map().
run(Socket, Executable) ->
    {ok, Server} = tmux_server:open(
        #{socket_path => Socket, executable => Executable}),
    tmux_scope:run_or_error(fun() ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"configured-job">>,
              launch => #{argv => [<<"/bin/cat">>]}}),
        tmux_scope:run_or_error(fun() ->
            Id = tmux_model:get(id, Session),
            Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
            Channel = <<"configured-", Suffix/binary>>,
            {ok, Wait} = tmux_command:wait_for(Channel, wait),
            {ok, Operation} = tmux_operation:start(Server, Wait, #{}),
            {ok, Source} = tmux_command:source_file(stdin, #{}),
            Scope = [<<"-t">>, Id, <<"@state">>],
            {ok, Settings} = tmux_command:raw(<<"set-option">>,
                Scope ++ [<<"configured">>]),
            {ok, Signal} = tmux_command:wait_for(Channel, signal),
            {ok, Text} = tmux_command:to_config([Settings, Signal]),
            {ok, _} = tmux_server:command(Server, Source, #{stdin => Text}),
            {ok, #{cleanup := complete}} =
                tmux_operation:await(Operation, 900),
            State = <<"@state">>,
            {ok, <<"configured">>} = tmux_option:get(Session, State, #{}),
            ParseOptions = #{parse_only => true},
            {ok, Parse} = tmux_command:source_file(stdin, ParseOptions),
            {ok, NewValue} = tmux_command:raw(<<"set-option">>,
                Scope ++ [<<"changed">>]),
            {ok, Change} = tmux_command:to_config(NewValue),
            {ok, _} = tmux_server:command(Server, Parse, #{stdin => Change}),
            {ok, <<"configured">>} = tmux_option:get(Session, State, #{}),
            #{configuration_applied => true, event_received => true,
              parse_only_kept_value => true}
        end, fun() ->
            {ok, _} = tmux_session:kill(Session),
            ok
        end)
    end, fun() ->
        ok = tmux_server:close(Server)
    end).
```

<!-- example-output: config_demo -->

```json
{
  "configuration_applied": true,
  "event_received": true,
  "parse_only_kept_value": true
}
```

The archive check repeats this program using the installed core package.
[Jobs and operations](jobs.md) covers operation ownership, cancellation and
application-level completion events.

## Choose input and execution separately

`tmux_command:to_config/1` renders one validated command value or a nonempty
flat list as native configuration text. Lists contain at most 256 commands and
share the 32 KiB rendered limit, including native separators. Rendering a list
does not provide atomic execution or rollback. Argument quoting preserves
literal bytes through the lexer, including variables, semicolons, newline
indentation and non-UTF-8 byte values. It returns ASCII text without
performing I/O. Escaping growth is bounded by a 32 KiB rendered limit. This
covers one lexer pass; native commands that accept command strings can parse
those strings again. Render each inner command separately for its own
boundary. Native commands still interpret their arguments and formats
normally; this renderer does not quote shell code.

`tmux_command:source_file/2` builds a command value without I/O. The source is
`stdin` or one absolute POSIX byte path. Path glob characters and backslashes
are quoted for tmux's glob parser; hash formats are not expanded. The builder
never opens the file. Reading and parsing occur when the command executes.
The file's size is not bounded by the command builder.

For stdin, pass bytes through the execution options of
`tmux_server:command/3` or `tmux_operation:start/3`. The transport bounds stdin
and rendered arguments together to 256 KiB. `parse_only` requests native
`-n`: parse the input without executing its command list. `quiet` requests
native missing-file suppression; syntax and execution errors remain errors.
Both options default to false.

Configuration is trusted tmux code, with native directives and variable
expansion. Parse-only is not a sandbox. Execution can change state before
reporting an error, and cancellation cannot roll back those effects. A
successful source command does not establish that background work launched
by that configuration has finished. Check its actual completion event.

## Coordinate channels explicitly

`tmux_command:wait_for/2` accepts a binary channel name and one action: `wait`,
`signal`, `lock` or `unlock`. Submit its result through the same execution
APIs. Native channel names are server-wide; use a name unique to the operation
when other clients share the server.

A signal wakes current waiters. On an unlocked channel with no waiters or
pending wakeup, it retains one wakeup for a later wait. Signaling again before
a wait can clear that pending state. Send once per expected wait; repeated
signals are neither counted nor reliably coalesced. Use separate names for
signaling and locking. `lock` and `unlock` expose native advisory channel
locks. A lock remains held after the acquiring command
client exits, until an explicit unlock. They are not library-owned leases.
Cancelling a command does not undo a signal or release a possibly acquired
lock. An uncertain lock outcome requires application coordination before
unlocking; blindly unlocking can release another client's lock.
