-module(tmux_pane).
-moduledoc """
Create, observe and rearrange panes using registered physical IDs.

`split/2` accepts a pane or a window; a window means its active pane
at execution. Options (`t:split_options/0`) are direction
(horizontal or vertical), size ({cells, N} or {percent, N}), before,
full_size, zoom, cwd, env, launch and detach. It defaults to a detached
vertical split. `get/2` returns newly observed fields; existing rows
remain unchanged. Reads span several commands and do not claim atomicity.
Launch and environment options follow `tmux_session:create/2`. An absent or
zero tmux pane_pid is represented as none. A captured positive PID is an
observation, not a guarantee that the process remains alive.

A successful split followed by a failed observation retains the completed
mutation and command result in its error. `kill/1` returns the
command result. Detached or stale references cannot act. All calls perform I/O
after validation.

`send_text/2` sends up to 2,000 literal bytes, including NUL, in one
command using tmux's hexadecimal key form. It adds no Enter key and never
splits a large input into partially applied commands. `send_keys/2`
accepts up to 256 named keys, single UTF-8 characters, {function, 1..12} and
{control, <<Letter>>}. Named keys are enter, tab, escape, backspace, space,
up, down, left, right, home, 'end', insert, delete, page_up, page_down and
back_tab. Terminal modes still govern how input is consumed; command
completion does not mean a program processed it.

`capture/2` returns stdout bytes unchanged, including final
newlines. Options (`t:capture_options/0`) are start and 'end' (line
integers or all), join_lines, escape_sequences, escape_control,
retain_trailing_spaces, alternate, pending and quiet. Defaults are tmux's
current-screen capture without escapes, joined wraps or padding. The
endpoint's output limit applies; an oversized capture returns an error.

Use `join/3`, `move/3` and `swap/3` to rearrange existing panes without
respawning their processes. `break/4` takes an explicit source window link:
breaking a window's only pane moves that membership, while breaking one of
several panes creates a new physical window. The [topology guide](panes.md)
shows the distinction. Use `get/2` or a new snapshot for updated parents and
indexes; actions leave captured values unchanged.

`pipe/3` connects a tmux-owned shell process to pane output, input or both.
It protects the shell text from tmux hash/strftime expansion; shell quoting
remains the caller's responsibility. `stop_pipe/1` closes that native pipe.
These actions do not create an Erlang output subscription or transfer process
ownership to the endpoint. Use an application acknowledgement for consumer
readiness, delivered bytes and job completion.
""".
-export([split/2, get/2, kill/1, resize/2, respawn/2, send_text/2, send_keys/2,
         capture/2, break/4, join/3, move/3, swap/3, pipe/3, stop_pipe/1]).

-export_type([split_options/0, capture_options/0, resize_options/0, respawn_options/0,
              coordinate/0, key/0, break_options/0, join_options/0, swap_options/0,
              pipe_command/0, pipe_options/0]).
-doc "Explicit shell code: a nonempty NUL-free binary, with no tmux format or strftime expansion.".
-type pipe_command() :: #{shell := binary()}.
-doc "Pipe direction defaults to output. toggle defaults false; true closes an existing pipe instead of replacing it.".
-type pipe_options() :: #{direction => output | input | both, toggle => boolean()}.
-doc """
Break placement: explicit destination index, optional literal window name.
detach defaults true.
""".
-type break_options() :: #{index := tmux_window_link:index(), name => binary(),
    detach => boolean()}.
-doc """
Join/move geometry: detach true, vertical split by default. before and
full_size follow tmux layout rules.
""".
-type join_options() :: #{direction => horizontal | vertical,
    size => {cells,1..2147483647} | {percent,1..100}, detach => boolean(),
    before => boolean(), full_size => boolean()}.
-doc """
Swap controls: detach defaults true; zoom maps to tmux -Z to retain zoom.
""".
-type swap_options() :: #{detach => boolean(), zoom => boolean()}.
-doc "Split geometry, placement and explicit launch options. Defaults to a detached vertical split.".
-type split_options() :: #{direction => horizontal | vertical,
    size => {cells,1..2147483647} | {percent,1..100}, before => boolean(),
    full_size => boolean(), zoom => boolean(), cwd => binary(),
    env => #{binary() => binary()}, launch => tmux_command:launch_spec(), detach => boolean()}.
-doc "Requested absolute pane dimensions in cells. Supply at least one dimension; tmux can clamp it to fit the layout.".
-type resize_options() :: #{width := 1..65535, height => 1..65535} |
                          #{width => 1..65535, height := 1..65535}.
-doc "Respawn options. Defaults: force false, launch previous, saved cwd. Environment augments tmux's resolved session environment for this spawn.".
-type respawn_options() :: #{force => boolean(), launch => tmux_command:respawn_spec(),
                             cwd => binary(), env => #{binary() => binary()}}.
-doc "A capture line coordinate, or all for tmux's full available range.".
-type coordinate() :: -2147483648..32767 | all.
-doc "Capture range and rendering flags. Byte output and its final newline are preserved.".
-type capture_options() :: #{start => coordinate(), 'end' => coordinate(),
    join_lines => boolean(), escape_sequences => boolean(), escape_control => boolean(),
    retain_trailing_spaces => boolean(), alternate => boolean(), pending => boolean(), quiet => boolean()}.
-doc "A validated named key, single UTF-8 character, function key or control-letter key.".
-type key() :: binary() | enter | tab | escape | backspace | space | up | down | left | right |
    home | 'end' | insert | delete | page_up | page_down | back_tab |
    {function,1..12} | {control,binary()}.

-doc """
Split a pane, or the supplied window's active pane, and observe the new pane.
Defaults to a detached vertical split. Options and launch semantics are
described in the module docs. Performs I/O; a post-creation read error retains
the completed mutation rather than pretending that no pane was created.
""".
-spec split(tmux_model:pane() | tmux_model:window(), split_options()) ->
    {ok, tmux_model:pane()} | {error, map()}.
split(Row, Options) ->
    maybe
        {ok, Flags, Launch} ?= tmux_args:launch_options(Options,
            [{direction, direction, <<>>}, {size, size, <<"-l">>},
             {before, flag, <<"-b">>}, {full_size, flag, <<"-f">>}, {zoom, flag, <<"-Z">>}]),
        {ok, Server, Target} ?= tmux_target:resolve([pane, window], Row),
        {ok, Result} ?= tmux_target:run(Server, <<"split-window">>,
            [<<"-P">>, <<"-F">>, <<"#{pane_id}">>, <<"-t">>, Target] ++
            Flags ++ [<<"--">> | Launch]),
        tmux_observe:created(Server, pane, Result)
    end.

-doc """
Read fresh fields for a physical pane ID. Performs I/O and returns target_gone
for a vanished pane. A captured PID remains an observation, not a live-process
guarantee.
""".
-spec get(tmux_server:t(), tmux_model:pane_id()) -> {ok, tmux_model:pane()} | {error, map()}.
get(Server, Id) -> tmux_observe:get(Server, pane, Id).

-doc """
Destroy this registered pane. Performs I/O after validating its origin and
stable ID; it never falls back to a positional target.
""".
-spec kill(tmux_model:pane()) -> {ok, map()} | {error, map()}.
kill(Pane) -> tmux_target:act(pane, Pane, <<"kill-pane">>, []).

-doc """
Connect a shell process to this registered physical pane, performing I/O.
An explicit nonempty `#{shell => Command}` is required (`t:pipe_command/0`).
tmux hash formats and strftime directives are escaped so the shell receives
the supplied text.
This does not quote values interpolated into shell code; the caller owns that
quoting. Executable argv is not accepted by this shell-only native command.
Encoding follows `tmux_command:literal_format/2` in time mode. A percent-bearing
command above its native 8191-byte intermediate limit returns `format_limit`
before dispatch, preserving any existing pipe.

`direction` (`t:pipe_options/0`) is `output` (default: pane output to child
stdin), `input` (child stdout to pane input) or `both`. `toggle` defaults false,
replacing any existing pipe. True maps to native `-o`: close an existing pipe without
starting another, or open one when none exists. A stopped pipe and replacement
can discard pending output. Await consumer acknowledgements before closing
if delivered bytes matter. This is a live PTY byte stream, not rendered
capture text or replay of terminal history; terminal modes affect its bytes.

The child is started by tmux through `/bin/sh -c`. Its stderr is discarded;
unused directions are routed to the native null device. No pane cwd or
environment copying is promised. A successful command result does not prove
exec success, readiness, delivery or child exit. The process is tmux-owned;
`tmux_server:close/1` preserves the borrowed pane and its pipe. This is not an
Erlang subscription with library flow control. Use `stop_pipe/1` to close the
pipe; stopping is not process cancellation or a wait for job completion.
""".
-spec pipe(tmux_model:pane(), pipe_command(), pipe_options()) ->
    {ok, map()} | {error, map()}.
pipe(Pane, #{shell := Shell} = Command, Options)
  when map_size(Command) =:= 1, is_binary(Shell), byte_size(Shell) > 0 ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{direction, pipe_direction, <<>>}, {toggle, flag, <<"-o">>}],
            #{direction => output}),
        {ok, Literal} ?= tmux_command:literal_format(Shell, time),
        {ok, Server, Target} ?= tmux_target:resolve(pane, Pane),
        tmux_target:run(Server, <<"pipe-pane">>,
            Flags ++ [<<"-t">>, Target, <<"--">>, Literal])
    end;
pipe(_, _, _) -> {error, #{code => invalid_pipe_command}}.

-doc """
Close this registered pane's native pipe, performing I/O. On a live pane,
closing an already closed pipe succeeds. An exited pane can produce a native
command error; a vanished ID returns `target_gone`.

Closing can discard pending bytes. It neither kills nor waits for an arbitrary
shell job started by `pipe/3`; applications must verify consumption and
process completion themselves. The endpoint does not own that shell process.
""".
-spec stop_pipe(tmux_model:pane()) -> {ok, map()} | {error, map()}.
stop_pipe(Pane) -> tmux_target:act(pane, Pane, <<"pipe-pane">>, []).

-doc """
Break a physical pane through its explicit source membership into a destination
session/index. Source, link and session must have the same registered owner.
The source link's expected window and the pane's observed parent are checked
before dispatch. The source selector also includes the stable pane ID, never
its positional index. Preflight and action are not atomic.

With multiple panes, tmux creates a new physical window. With only one pane,
it moves the selected source membership, preserving the existing window and
its other links. Moving the final membership out can remove the source session.
Pane IDs and processes remain; indexes and option inheritance can change.
name is a literal UTF-8 argument, subject to native name cleaning.
An occupied destination index is refused. detach defaults true; false selects
the destination membership. Session groups retain native synchronization.

Returns the command result consistently for both cases. Use `get/2` or
`tmux_window_link:get/3` for fresh observations. Even an eventual native error
can unzoom a window; this is not a transaction and is never retried.
""".
-spec break(tmux_model:pane(), tmux_model:window_link(), tmux_model:session(),
    break_options()) -> {ok, tmux_operation:completed()} | {error, map()}.
break(Pane, SourceLink, Session, Options) ->
    maybe
        {ok, Index, Flags} ?= break_options(Options),
        {ok, Server} ?= tmux_target:same_owner(pane, Pane, window_link, SourceLink),
        {ok, Server} ?= tmux_target:same_owner(pane, Pane, session, Session),
        {ok, Source} ?= tmux_target:linked_pane(Server, Pane, SourceLink),
        {ok, SessionTarget} ?= tmux_target:selector(session, tmux_model:get(id, Session)),
        Target = <<SessionTarget/binary, Index/binary>>,
        tmux_target:run(Server, <<"break-pane">>, Flags ++ [<<"-s">>, Source, <<"-t">>, Target])
    end.

-doc """
Move a source pane into a split beside the destination pane. Both physical IDs
must belong to the same registered owner and must differ. Geometry follows
`t:join_options/0`. Existing processes and pane IDs survive; dimensions,
indexes and inherited window options can change. Removing a window's last
pane destroys that physical window and its links, and can remove sessions.

Default detach true avoids selecting the resolved destination session; false
uses tmux's resolved session context for the destination pane. Shared physical
windows affect all their memberships. Returns the command result without
refreshing either row. Use `get/2` for current fields. No retry is performed.
""".
-spec join(tmux_model:pane(), tmux_model:pane(), join_options()) ->
    {ok, tmux_operation:completed()} | {error, map()}.
join(Source, Destination, Options) -> relocate(<<"join-pane">>, Source, Destination, Options).

-doc """
Rearrange a source pane beside the destination, including within one window.
Uses native move-pane, whose placement and lifetime behavior follow `join/3`.
Both calls use explicit physical IDs and leave captured rows unchanged.
""".
-spec move(tmux_model:pane(), tmux_model:pane(), join_options()) ->
    {ok, tmux_operation:completed()} | {error, map()}.
move(Source, Destination, Options) -> relocate(<<"move-pane">>, Source, Destination, Options).

-doc """
Exchange two panes' layout positions within or across physical windows.
Preserves their IDs and processes; parent windows, dimensions, indexes and
inherited options can change. Both rows require the same registered owner.
detach defaults true; active positions can still receive different panes.
zoom maps to native -Z. Identical IDs do not exchange panes, but native zoom
handling still runs; the default can unzoom even a same-pane swap.
Returns the command result; `get/2` observes the resulting values explicitly.
""".
-spec swap(tmux_model:pane(), tmux_model:pane(), swap_options()) ->
    {ok, tmux_operation:completed()} | {error, map()}.
swap(Source, Destination, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{detach, flag, <<"-d">>}, {zoom, flag, <<"-Z">>}], #{detach => true}),
        {ok, Server, From, To} ?= pane_targets(Source, Destination),
        tmux_target:run(Server, <<"swap-pane">>, Flags ++ [<<"-s">>, From, <<"-t">>, To])
    end.

relocate(Command, Source, Destination, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{detach, flag, <<"-d">>}, {direction, direction, <<>>},
             {size, size, <<"-l">>}, {before, flag, <<"-b">>},
             {full_size, flag, <<"-f">>}], #{detach => true}),
        {ok, Server, From, To} ?= pane_targets(Source, Destination),
        ok ?= case From =:= To of true -> {error, #{code => same_pane}}; false -> ok end,
        tmux_target:run(Server, Command, Flags ++ [<<"-s">>, From, <<"-t">>, To])
    end.

pane_targets(Source, Destination) ->
    maybe
        {ok, Server} ?= tmux_target:same_owner(pane, Source, pane, Destination),
        {ok, From} ?= tmux_target:selector(pane, tmux_model:get(id, Source)),
        {ok, To} ?= tmux_target:selector(pane, tmux_model:get(id, Destination)),
        {ok, Server, From, To}
    end.

break_options(Options) when is_map(Options) ->
    maybe
        {ok, Index} ?= case maps:find(index, Options) of
            {ok, Value} when is_integer(Value, 0, 2147483647) ->
                {ok, integer_to_binary(Value)};
            {ok, _} -> {error, #{code => invalid_option, path => [index]}};
            error -> {error, #{code => missing_option, path => [index]}}
        end,
        {ok, Flags} ?= tmux_args:options(maps:remove(index, Options),
            [{detach, flag, <<"-d">>}, {name, text, <<"-n">>}], #{detach => true}),
        {ok, Index, Flags}
    end;
break_options(_) -> {error, #{code => invalid_options, path => []}}.

-doc """
Request an absolute width, height or both for this registered physical pane.
Performs I/O after validating dimensions and origin. tmux can clamp the
request to its layout constraints and can resize neighboring panes. Resizing a
tiled pane unzooms its window. Use `get/2` for actual dimensions; the input
row is unchanged. The accepted library range is not a promise that every
server accepts every dimension: tmux versions can impose tighter limits and
return a command error.

An empty request is rejected before dispatch:

```erlang
1> tmux_pane:resize(invalid_row, #{}).
{error,#{code => empty_resize}}
```
""".
-spec resize(tmux_model:pane(), resize_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
resize(Pane, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{width, dimension, <<"-x">>}, {height, dimension, <<"-y">>}]),
        ok ?= case Flags of [] -> {error, #{code => empty_resize}}; _ -> ok end,
        {ok, Server, Target} ?= tmux_target:resolve(pane, Pane),
        tmux_target:run(Server, <<"resize-pane">>, Flags ++ [<<"-t">>, Target])
    end.

-doc """
Respawn this registered physical pane, keeping its pane ID. force defaults
false and a running pane normally returns command_error. force = true lets
tmux close its existing PTY before spawning again. This acknowledges the tmux
command, not former-job termination or successful application initialization.
The old PTY can already be closed if a later spawn step fails.

launch defaults to previous, reusing tmux's saved argv or shell. An explicit
argv or shell map replaces that command. default_shell is invalid here because
absent respawn arguments mean saved-command reuse. Omitted cwd retains the
saved launch directory, rather than the program's current directory. env
augments the session environment tmux resolves for this physical pane; a
captured membership does not pin that context. Prior per-spawn overrides are
not automatically reapplied. Other launch rules follow
`tmux_session:create/2`.

Performs I/O after validation. Existing rows retain their observations; use
`get/2` and an application readiness condition to inspect the new process. An
uncertain result is not permission to replay this mutation automatically.

Unsupported launch modes fail before dispatch:

```erlang
1> tmux_pane:respawn(invalid_row, #{launch => default_shell}).
{error,#{code => invalid_launch}}
```
""".
-spec respawn(tmux_model:pane(), respawn_options()) ->
    {ok, tmux_operation:completed()} | {error, tmux_operation:failure()}.
respawn(Pane, Options) ->
    maybe
        {ok, Flags, Launch} ?= tmux_args:respawn_options(Options),
        {ok, Server, Target} ?= tmux_target:resolve(pane, Pane),
        tmux_target:run(Server, <<"respawn-pane">>,
            Flags ++ [<<"-t">>, Target, <<"--">> | Launch])
    end.

-doc """
Send at most 2,000 literal bytes as hexadecimal tmux keys. Adds no Enter key
and does not invoke a shell. Performs I/O in one command; oversized input is
rejected before partial submission. Completion does not prove that a terminal
program processed the input.
""".
-spec send_text(tmux_model:pane(), binary()) -> {ok, map()} | {error, map()}.
send_text(Pane, Bytes) when is_binary(Bytes), byte_size(Bytes) =< 2000 ->
    Hex = [integer_to_binary(Byte, 16) || <<Byte>> <= Bytes],
    send(Pane, [<<"-H">>], Hex);
send_text(_, Bytes) when is_binary(Bytes) -> {error, #{code => command_limit}};
send_text(_, _) -> {error, #{code => invalid_text}}.

-doc """
Send at most 256 validated key tokens. Named keys, single UTF-8 characters,
function keys and control-letter tuples are supported. Performs I/O; terminal
modes determine the resulting input bytes. Use `send_text/2` for arbitrary
bytes.
""".
-spec send_keys(tmux_model:pane(), [key()]) -> {ok, map()} | {error, map()}.
send_keys(Pane, Keys) ->
    maybe
        {ok, Arguments} ?= keys(Keys, 256, []),
        send(Pane, [], Arguments)
    end.

-doc """
Capture terminal bytes, preserving final newlines. Options select line range,
joined wraps, escapes, alternate screen and padding; defaults follow tmux
current-screen capture. Performs I/O and returns an explicit output-limit
error instead of silently truncating.
""".
-spec capture(tmux_model:pane(), capture_options()) -> {ok, binary()} | {error, map()}.
capture(Pane, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{start, coordinate, <<"-S">>}, {'end', coordinate, <<"-E">>},
             {join_lines, flag, <<"-J">>}, {escape_sequences, flag, <<"-e">>},
             {escape_control, flag, <<"-C">>}, {retain_trailing_spaces, flag, <<"-N">>},
             {alternate, flag, <<"-a">>}, {pending, flag, <<"-P">>}, {quiet, flag, <<"-q">>}]),
        {ok, Server, Target} ?= tmux_target:resolve(pane, Pane),
        {ok, #{stdout := Bytes}} ?= tmux_target:run(Server, <<"capture-pane">>,
            [<<"-p">>, <<"-t">>, Target | Flags]),
        {ok, Bytes}
    end.

send(Pane, Flags, Arguments) ->
    maybe
        {ok, Server, Target} ?= tmux_target:resolve(pane, Pane),
        tmux_target:run(Server, <<"send-keys">>,
            [<<"-t">>, Target] ++ Flags ++ [<<"--">> | Arguments])
    end.

keys([], _, Acc) -> {ok, lists:reverse(Acc)};
keys([_ | _], 0, _) -> {error, #{code => command_limit}};
keys([Key | Rest], Remaining, Acc) ->
    maybe
        {ok, Encoded} ?= key(Key),
        keys(Rest, Remaining - 1, [Encoded | Acc])
    end;
keys(_, _, _) -> {error, #{code => invalid_keys}}.

key({function, N}) when is_integer(N, 1, 12) -> {ok, <<$F, (integer_to_binary(N))/binary>>};
key({control, <<C>>}) when C >= $a, C =< $z -> {ok, <<"C-", C>>};
key(Bytes) when is_binary(Bytes), byte_size(Bytes) =< 4 ->
    case unicode:characters_to_list(Bytes) of
        [Codepoint] when Codepoint >= 32, Codepoint =/= 127 -> {ok, Bytes};
        _ -> {error, #{code => invalid_key}}
    end;
key(Name) ->
    Names = #{enter => <<"Enter">>, tab => <<"Tab">>, escape => <<"Escape">>,
        backspace => <<"BSpace">>, space => <<"Space">>, up => <<"Up">>, down => <<"Down">>,
        left => <<"Left">>, right => <<"Right">>, home => <<"Home">>, 'end' => <<"End">>,
        insert => <<"IC">>, delete => <<"DC">>, page_up => <<"PPage">>,
        page_down => <<"NPage">>, back_tab => <<"BTab">>},
    case maps:find(Name, Names) of
        {ok, Value} -> {ok, Value};
        error -> {error, #{code => invalid_key}}
    end.
