# Apply configuration and await its completion signal

Submit a wait without blocking the caller, then load configuration that sets
an owned session option and signals the channel.

- The signal works whether the waiter arrives before or after it.
- The program checks the stored value, then checks that parse-only loading
  leaves it unchanged.
- The runner supplies the daemon.

Compile the project first:

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

[Jobs and operations](jobs.md) covers operation ownership, cancellation and
application-level completion events.

## Render configuration

- `tmux_command:to_config/1` renders one validated command, or a nonempty flat
  list, as native configuration text. It does no I/O.
- A list holds at most 256 commands and shares the 32 KiB rendered limit,
  including native separators. Rendering a list gives no atomic execution or
  rollback.
- Quoting keeps literal bytes through the lexer: variables, semicolons,
  newline indentation and non-UTF-8 bytes. The result is ASCII text.
- That covers one lexer pass. Native commands that take command strings can
  parse those strings again, so render each inner command separately for its
  own boundary.
- Native commands still interpret their arguments and formats. The renderer
  does not quote shell code.

## Source a file or stdin

- `tmux_command:source_file/2` builds a command value without I/O. The source
  is `stdin` or one absolute POSIX byte path.
- Glob characters and backslashes in a path are quoted for tmux's glob parser.
  Hash formats are not expanded.
- The builder never opens the file. Reading and parsing happen when the command
  runs, and the file size is not bounded by the builder.
- For stdin, pass bytes in the execution options of `tmux_server:command/3` or
  `tmux_operation:start/3`. The transport bounds stdin and rendered arguments
  together to 256 KiB.
- `parse_only` requests native `-n`: parse without executing. `quiet` requests
  native missing-file suppression. Syntax and execution errors stay errors.
  Both default to false.

Configuration is trusted tmux code, with native directives and variable
expansion.

- Parse-only is not a sandbox.
- Execution can change state before it reports an error. Cancellation cannot
  roll that back.
- A successful source command does not mean background work it launched has
  finished. Check that work's own completion event.

## Coordinate channels

- `tmux_command:wait_for/2` takes a binary channel name and one action: `wait`,
  `signal`, `lock` or `unlock`. Submit the result through the same execution
  APIs.
- Channel names are server-wide. Use a name unique to the operation when other
  clients share the server.
- A signal wakes current waiters. On an unlocked channel with no waiters or
  pending wakeup, it keeps one wakeup for a later wait. Signalling again before
  a wait can clear that state.
- Send one signal per expected wait. Repeated signals are not counted or
  reliably coalesced. Use separate names for signalling and locking.
- `lock` and `unlock` are native advisory locks, not library-owned leases. A
  lock stays held after the acquiring client exits, until an explicit unlock.
- Cancelling a command does not undo a signal or release a lock it may have
  taken.
- After an uncertain lock outcome, coordinate in your application before you
  unlock. A blind unlock can release another client's lock.
