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

Use literal_format only for a whole argument that tmux expands as a format,
such as a new name or cwd. It does not encode a value nested in a format
expression. tmux's stored-name escaping and session-name substitutions still
apply. Use literal_format(Value, time) for commands such as display-message
that also expand strftime percent directives. No renderer reverses stored-name
semantics.

launch distinguishes executable argv from an explicitly requested shell
command. A singleton argv uses the installed helper's exec-only mode because
tmux otherwise passes one argument to its default shell. Empty argv is invalid;
default_shell explicitly requests tmux's configured default command/shell.
""".
-export([raw/2, validate/1, argv/1, literal_format/1, literal_format/2, launch/1]).
-export_type([t/0]).

-export_type([launch_spec/0]).
-doc "Explicit executable argv, an explicitly requested shell command, or tmux's configured default shell.".
-type launch_spec() :: default_shell | #{argv := nonempty_list(binary())} | #{shell := binary()}.

-export_type([respawn_spec/0]).
-doc "Reuse tmux's saved command/shell, or explicitly replace it with argv or a shell command. Used by pane/window respawn, not launch/1.".
-type respawn_spec() :: previous | #{argv := nonempty_list(binary())} | #{shell := binary()}.

-doc """
A validated single-command value. Rendering and execution remain separate.
""".
-opaque t() :: {tmux_command, binary(), [binary()]}.

-doc """
Validate one trusted command name and binary argv, without I/O. The renderer
protects tmux separators; it does not provide shell or nested-format quoting.
External services still need their own allowlists and write policy.
Names are at most 128 bytes. NUL bytes are rejected, and at most 2,040
arguments fit within a 32 KiB command reservation including framing overhead.
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
remain tmux's own. Performs no I/O.
""".
-spec literal_format(binary(), tmux | time) -> {ok, binary()} | {error, map()}.
literal_format(Value, Mode) when Mode =:= tmux; Mode =:= time ->
    maybe
        ok ?= word(Value),
        Hashes = binary:replace(Value, <<"#">>, <<"##">>, [global]),
        Encoded = case Mode of
            tmux -> Hashes;
            time -> binary:replace(Hashes, <<"%">>, <<"%%">>, [global])
        end,
        case byte_size(Encoded) =< 32768 of
            true -> {ok, Encoded};
            false -> {error, #{code => command_limit}}
        end
    end;
literal_format(_, _) -> {error, #{code => invalid_format_mode}}.

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
                Helper = unicode:characters_to_binary(filename:join(Priv, "tmux_owned_io")),
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
