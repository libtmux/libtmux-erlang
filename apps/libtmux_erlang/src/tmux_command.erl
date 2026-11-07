-module(tmux_command).
-moduledoc """
Build one tmux command without performing I/O.

Arguments remain binary values. Rendering protects trailing semicolons from
tmux's command separator parser. This is distinct from shell quoting and from
format expansion. A raw command is trusted application code; external services
must apply their own command allowlist and write policy.

```erlang
1> {ok, C} = tmux_command:raw(<<"list-panes">>, [<<"-a">>]), ok.
ok
2> tmux_command:argv(C).
[<<"list-panes">>,<<"-a">>]
3> tmux_command:literal_format(<<"api-#{pane_id}">>).
{ok,<<"api-##{pane_id}">>}
4> tmux_command:launch(#{argv => [<<"/bin/printf">>, <<"hello">>]}).
{ok,[<<"/bin/printf">>,<<"hello">>]}
```

Use `literal_format/1` only for a whole argument that tmux
expands as a format, such as a new name or cwd. It does not encode a value
nested in a format expression. tmux's stored-name escaping and session-name
substitutions still apply. Use `literal_format/2` with mode time
for commands such as display-message that also expand strftime percent
directives. This protects one format-expansion pass, not later visual style
rendering or recursive/nested expansion. No renderer reverses stored-name
semantics.

`launch/1` distinguishes executable argv from an explicitly
requested shell command. A singleton argv uses the installed helper's
exec-only mode because tmux otherwise passes one argument to its default
shell. Empty argv is invalid; default_shell explicitly requests tmux's
configured default command/shell. The internal helper uses an absolute path so
a child's cwd does not change helper resolution. Relative executable arguments
retain their native meaning.

Empty shell commands have command-specific lifetime. split-window creates a
process-free pane. new-session executes an empty shell command and can remove
the new object immediately. new-window does likewise before tmux 3.8; tmux 3.8
creates a process-free pane. Use a persistent job for parent sessions/windows
that must remain available across supported versions.

Submit commands through `tmux_server:command/3` or `tmux_operation:start/3`.
The [job guide](jobs.md) shows submission, completion and cancellation.

`wait_for/2` builds native channel signals, waits and advisory locks.
`source_file/2` builds configuration loading from stdin or a literal absolute
path. Both return command values without opening an endpoint or doing I/O.
""".
-export([raw/2, validate/1, argv/1, literal_format/1, literal_format/2, launch/1,
         wait_for/2, source_file/2]).
-export_type([t/0]).
-export_type([wait_action/0, source/0, source_options/0]).

-doc "Native wait channel action. lock/unlock are explicit advisory operations, not owned leases.".
-type wait_action() :: wait | signal | lock | unlock.
-doc "Standard input, or one literal absolute POSIX byte path with no NUL.".
-type source() :: stdin | binary().
-doc "Native parse-only and quiet-missing-file flags; both default to false.".
-type source_options() :: #{parse_only => boolean(), quiet => boolean()}.

-export_type([launch_spec/0]).
-doc "Explicit executable argv, an explicitly requested shell command, or tmux's configured default shell.".
-type launch_spec() :: default_shell | #{argv := nonempty_list(binary())} | #{shell := binary()}.

-export_type([respawn_spec/0]).
-doc """
Reuse tmux's saved command/shell, or replace it with argv or a shell command.
Used by `tmux_pane:respawn/2` and `tmux_window:respawn/2`.
""".
-type respawn_spec() :: previous | #{argv := nonempty_list(binary())} | #{shell := binary()}.

-doc """
A validated single-command value. Rendering and execution remain separate.
""".
-opaque t() :: {tmux_command, binary(), [binary()]}.

-doc """
Validate one trusted command name and binary argv, without I/O. The renderer
protects tmux separators; it does not provide shell or nested-format quoting.
External services still need their own allowlists and write policy. Names are
at most 128 bytes. NUL bytes are rejected, and at most 2,040 arguments fit
within a 32 KiB command reservation including framing overhead.
""".
-spec raw(binary(), [binary()]) -> {ok, t()} | {error, map()}.
raw(Name, Arguments) ->
    case valid_name(Name) of
        false -> {error, #{code => invalid_command}};
        true ->
            maybe
                ok ?= words(Arguments, 2040, byte_size(Name) + 2),
                {ok, {tmux_command, compact(Name), [compact(A) || A <- Arguments]}}
            end
    end.

-doc """
Build a native `wait-for` command without I/O. Channels are nonempty NUL-free
binary names, subject to the command reservation in `raw/2`; neither shell nor
format expansion occurs. Submit through `tmux_operation:start/3` for a wait
that leaves the caller free, or through `tmux_server:command/3` to await it.

`signal` wakes current waiters. On an unlocked channel with no waiters or
pending wakeup, it retains one wakeup for a later wait. Signaling that channel
again before a wait can clear the pending state. Signals are neither counted
nor reliably coalesced events; send once per expected wait. Channel names are
shared by all clients of the server. Use separate names for signaling and
locking. `lock` acquires an advisory channel lock or waits
for an explicit `unlock`; a completed command client's exit does not release
its acquired lock. Unlocking an unlocked channel is a native command error.

Cancellation retires the library client. It does not undo a signal or release
a lock that may already have been acquired; an uncertain lock outcome needs
application coordination before another unlock. This is not an owned mutex.

```erlang
1> {ok, Signal} = tmux_command:wait_for(<<"build-ready">>, signal), ok.
ok
2> tmux_command:argv(Signal).
[<<"wait-for">>,<<"-S">>,<<"--">>,<<"build-ready">>]
```
""".
-spec wait_for(binary(), wait_action()) -> {ok, t()} | {error, map()}.
wait_for(Channel, Action) ->
    maybe
        {ok, Flags} ?= case Action of
            wait -> {ok, []};
            signal -> {ok, [<<"-S">>]};
            lock -> {ok, [<<"-L">>]};
            unlock -> {ok, [<<"-U">>]};
            _ -> {error, #{code => invalid_wait_action}}
        end,
        ok ?= case Channel of <<>> -> {error, #{code => invalid_channel}}; _ -> word(Channel) end,
        raw(<<"wait-for">>, Flags ++ [<<"--">>, Channel])
    end.

-doc """
Build configuration loading from stdin or one literal absolute path, without
I/O. `stdin` renders `source-file -`; supply configuration bytes in the
`stdin` option of `tmux_server:command/3` or `tmux_operation:start/3`. Those
APIs bound input to 256 KiB including their argument reservation.

Paths are NUL-free POSIX byte binaries. Glob metacharacters and backslashes
are escaped so only that filename is selected; format expansion is disabled.
The combined encoded path and flags must fit `raw/2` limits. The file is read
by tmux at execution time; this builder does not open it or bound its size.

`parse_only` requests native `-n` parsing without executing the configuration's
command list. `quiet` requests native `-q` missing-file suppression; it does
not suppress syntax or execution errors. Both default to false. Configuration
is trusted tmux code, with its own variable, directive and command semantics.
Parse-only is not a sandbox. Execution can partially change server state before
an error; cancellation cannot undo those effects. Completion does not prove
that background jobs launched by the configuration have finished.

```erlang
1> {ok, Source} = tmux_command:source_file(stdin, #{parse_only => true}), ok.
ok
2> tmux_command:argv(Source).
[<<"source-file">>,<<"-n">>,<<"--">>,<<"-">>]
```
""".
-spec source_file(source(), source_options()) -> {ok, t()} | {error, map()}.
source_file(Source, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{parse_only, flag, <<"-n">>}, {quiet, flag, <<"-q">>}]),
        {ok, Path} ?= source_path(Source),
        raw(<<"source-file">>, Flags ++ [<<"--">>, Path])
    end.

source_path(stdin) -> {ok, <<"-">>};
source_path(<<$/, _/binary>> = Path) ->
    maybe
        ok ?= word(Path),
        {ok, << <<(glob_byte(C))/binary>> || <<C>> <= Path >>}
    end;
source_path(_) -> {error, #{code => invalid_source_path}}.

glob_byte(C) when C =:= $*; C =:= $?; C =:= $[; C =:= $]; C =:= $\\ -> <<$\\, C>>;
glob_byte(C) -> <<C>>.

-doc """
Revalidate a command value at a submission boundary. Returns a compact
validated command or a tagged shape/argument/resource error, without I/O.
""".
-spec validate(term()) -> {ok, t()} | {error, map()}.
validate({tmux_command, Name, Arguments}) -> raw(Name, Arguments);
validate(_) -> {error, #{code => invalid_command}}.

-doc """
Render a validated command into executable argv, protecting trailing tmux
separators. Performs no I/O and raises for an invalid command value.
""".
-spec argv(t()) -> [binary()].
argv(Command) ->
    case validate(Command) of
        {ok, {tmux_command, Name, Arguments}} ->
            [Name | [escape_separator(Word) || Word <- Arguments]];
        {error, Detail} -> error({invalid_command, Detail})
    end.

-doc """
Quote a complete literal argument for tmux format expansion. This does not
encode operands nested inside another format expression. Performs no I/O.
""".
-spec literal_format(binary()) -> {ok, binary()} | {error, map()}.
literal_format(Value) ->
    literal_format(Value, tmux).

-doc """
Quote a complete literal format argument. Mode tmux protects hash expansion;
mode time also protects strftime percent directives. Stored-name semantics
remain tmux's own. This handles one expansion pass, not a nested operand,
recursive expansion or later visual style rendering. Performs no I/O.

Hash runs before `[` stay unchanged because tmux preserves style-looking
prefixes for a separate drawing step. Other hashes are doubled. In time mode,
an argument containing percent bytes must fit tmux's 8191-byte strftime result
limit after hash encoding and before percent doubling; larger values return
`format_limit` with `time_bytes` and `max_bytes`. Arguments without percent
bytes skip that native time-expansion limit. The encoded 32 KiB command limit
still applies in either mode.
""".
-spec literal_format(binary(), tmux | time) -> {ok, binary()} | {error, map()}.
literal_format(Value, Mode) when Mode =:= tmux; Mode =:= time ->
    maybe
        ok ?= word(Value),
        Hashes = literal_hashes(Value),
        Encoded = case Mode of
            tmux -> Hashes;
            time -> binary:replace(Hashes, <<"%">>, <<"%%">>, [global])
        end,
        Time = Mode =:= time andalso binary:match(Value, <<"%">>) =/= nomatch,
        case {byte_size(Encoded) =< 32768, Time andalso byte_size(Hashes) > 8191} of
            {false, _} -> {error, #{code => command_limit}};
            {_, true} -> {error, #{code => format_limit, max_bytes => 8191,
                                  time_bytes => byte_size(Hashes)}};
            _ -> {ok, Encoded}
        end
    end;
literal_format(_, _) -> {error, #{code => invalid_format_mode}}.

literal_hashes(Value) ->
    case binary:match(Value, <<"#">>) of
        nomatch -> Value;
        _ -> iolist_to_binary(lists:reverse(literal_hashes(Value, [])))
    end.

literal_hashes(<<>>, Acc) -> Acc;
literal_hashes(<<$#, Rest/binary>>, Acc) ->
    {Count, Tail} = hash_run(Rest, 1),
    Size = case Tail of <<$[, _/binary>> -> Count; _ -> Count * 2 end,
    literal_hashes(Tail, [binary:copy(<<$#>>, Size) | Acc]);
literal_hashes(<<Byte, Rest/binary>>, Acc) -> literal_hashes(Rest, [Byte | Acc]).

hash_run(<<$#, Rest/binary>>, Count) -> hash_run(Rest, Count + 1);
hash_run(Tail, Count) -> {Count, Tail}.

-doc """
Render explicit executable argv, an explicitly requested shell command, or
default_shell. Singleton argv uses the installed helper's exec-only mode to
avoid tmux interpreting it as shell syntax. Performs no I/O.
""".
-spec launch(launch_spec()) ->
    {ok, [binary()]} | {error, map()}.
launch(default_shell) -> {ok, []};
launch(#{argv := [Executable]} = Spec) when map_size(Spec) =:= 1 ->
    maybe
        ok ?= executable(Executable),
        case code:priv_dir(libtmux_erlang) of
            {error, _} -> {error, #{code => application_unavailable}};
            Priv ->
                Path = filename:absname(filename:join(Priv, "tmux_owned_io")),
                Helper = unicode:characters_to_binary(Path),
                {ok, [Helper, <<"--exec-one">>, Executable]}
        end
    end;
launch(#{argv := [Executable, _ | _] = Arguments} = Spec) when map_size(Spec) =:= 1 ->
    maybe
        ok ?= executable(Executable),
        ok ?= words(Arguments, 2040, 0),
        {ok, Arguments}
    end;
launch(#{shell := Shell} = Spec) when map_size(Spec) =:= 1 ->
    maybe
        ok ?= word(Shell),
        {ok, [Shell]}
    end;
launch(_) -> {error, #{code => invalid_launch}}.

valid_name(<<First, Rest/binary>> = Name)
  when First >= $a, First =< $z, byte_size(Name) =< 128 ->
    valid_name_bytes(Rest);
valid_name(_) -> false.

valid_name_bytes(<<>>) -> true;
valid_name_bytes(<<C, Rest/binary>>) when (C >= $a andalso C =< $z) orelse C =:= $- ->
    valid_name_bytes(Rest);
valid_name_bytes(_) -> false.

word(Value) when is_binary(Value), byte_size(Value) =< 32768 ->
    case binary:match(Value, <<0>>) of
        nomatch -> ok;
        _ -> {error, #{code => invalid_argument}}
    end;
word(Value) when is_binary(Value) -> {error, #{code => command_limit}};
word(_) -> {error, #{code => invalid_argument}}.

words([], _, _) -> ok;
words([_ | _], 0, _) -> {error, #{code => command_limit}};
words([Value | Rest], Remaining, Size) ->
    maybe
        ok ?= word(Value),
        NewSize = Size + byte_size(Value) + 3,
        case NewSize =< 32768 of
            true -> words(Rest, Remaining - 1, NewSize);
            false -> {error, #{code => command_limit}}
        end
    end;
words(_, _, _) -> {error, #{code => invalid_argument}}.

executable(<<>>) -> {error, #{code => invalid_executable}};
executable(Value) -> word(Value).

compact(Bytes) ->
    case binary:referenced_byte_size(Bytes) =:= byte_size(Bytes) of
        true -> Bytes;
        false -> binary:copy(Bytes)
    end.

escape_separator(<<>>) -> <<>>;
escape_separator(Word) ->
    case binary:last(Word) of
        $; ->
            Prefix = binary:part(Word, 0, byte_size(Word) - 1),
            <<Prefix/binary, $\\, $;>>;
        _ -> Word
    end.
