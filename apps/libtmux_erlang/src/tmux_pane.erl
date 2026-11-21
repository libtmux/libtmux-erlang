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
command result. Detached or stale references cannot act. `resize_command/2`
builds a reusable value without tmux I/O; the other calls perform I/O after
validation.

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

`wait_exit/2` waits for a pane's process to exit and reports an exit status or
the signal that ended it, as two distinct values. The pane must retain its dead
state through `remain-on-exit`; the [job guide](jobs.md) shows it with a job
that also acknowledges its output.

## What is on here

No call here refreshes the row you pass in; read the pane again to see a
change. Each group below lists its calls, including a few that live in sibling
modules.

**Creating and reading.** `split/2` splits a pane, or a window's active pane,
and returns the new pane's row. `get/2` reads a pane's fresh fields by its
stable ID. `tmux_snapshot:panes/1` lists the panes of a captured graph.

`split/2`, `get/2`, `t:split_options/0` and `tmux_snapshot:panes/1`

**Sending input.** `send_text/2` sends literal bytes and adds no Enter key.
`send_keys/2` sends named keys, single characters, function keys and control
keys. A successful call does not show that a program processed the input, so
read the pane afterwards. `tmux_buffer:paste/3` pastes a stored buffer instead.

`send_text/2`, `send_keys/2`, `t:key/0` and `tmux_buffer:paste/3`

**Reading output.** `capture/2` returns the pane's terminal text as bytes,
keeping the final newline, over the line range you choose. `pipe/3` connects a
tmux-owned shell process to the pane's live byte stream, and `stop_pipe/1`
closes that pipe.

- Capture: `capture/2`, `t:capture_options/0` and `t:coordinate/0`
- Pipe: `pipe/3`, `stop_pipe/1`, `t:pipe_command/0` and `t:pipe_options/0`

**Resizing.** `resize/2` requests an absolute width, height or both, which tmux
can clamp to fit the layout. `resize_command/2` builds the same command without
contacting tmux, so you can submit it later.

`resize/2`, `resize_command/2`, `t:resize_options/0`, `tmux_server:command/3`
and `tmux_operation:start/3`

**Rearranging.** `break/4` breaks a pane out into a new window, or moves the
window's membership when the pane is its only one. `join/3` and `move/3` place a
pane beside another, and `swap/3` exchanges two panes' positions. The processes
and pane IDs survive each of them. `tmux_window:select_layout/2` arranges every
pane of a window at once.

`break/4`, `join/3`, `move/3`, `swap/3`, `t:break_options/0`,
`t:join_options/0`, `t:swap_options/0` and `tmux_window:select_layout/2`

**Restarting and removing.** `respawn/2` runs the pane's command again under the
same pane ID, and a running pane needs `force`. `kill/1` destroys the pane and
never falls back to a positional target.

`respawn/2`, `t:respawn_options/0` and `kill/1`

**Waiting for exit.** `wait_exit/2` waits for the pane's process to exit and
reports its exit status or the signal that ended it. The pane must keep its
dead state through `remain-on-exit`.

`wait_exit/2`, `t:wait_exit_options/0`, `t:wait_exit_result/0` and `t:exit/0`

**Waiting for text.** `wait_for_text/3` reads a live pane on a private owned
server until its current screen contains the requested bytes. Use
`tmux_pane_text:start/3` to begin sampling before sending input.
""".
-export([split/2, get/2, kill/1, resize/2, respawn/2, send_text/2, send_keys/2,
         capture/2, break/4, join/3, move/3, swap/3, pipe/3, stop_pipe/1, wait_exit/2]).
-export([resize_command/2]).
-export([wait_for_text/3]).

-export_type([split_options/0, capture_options/0, resize_options/0, respawn_options/0,
              coordinate/0, key/0, break_options/0, join_options/0, swap_options/0,
              pipe_command/0, pipe_options/0, wait_exit_options/0, exit/0,
              wait_exit_result/0]).
-doc """
Wait options: `deadline_ms` (1 to 600000, default 30000) bounds the whole wait,
including the final observation.
""".
-type wait_exit_options() :: #{deadline_ms => 1..600000}.
-doc """
How a pane's process ended: `{status, Code}` for a normal exit, or
`{signal, Signal}` for a death by signal. tmux prints a signal as its number on
Linux and as a lowercase name on systems with `sys_signame`.
""".
-type exit() :: {status, 0..255} | {signal, pos_integer() | binary()}.
-doc "The exit outcome and a fresh observation of the pane ID. A concurrent respawn can change its process.".
-type wait_exit_result() :: #{exit := exit(), pane := tmux_model:pane()}.
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
Wait until this registered pane's process exits and report how it ended.
Performs I/O. The result carries `exit` (`t:exit/0`: an exit status or a
signal) and the dead `pane`, freshly observed. An already published exit
returns at once.

tmux keeps a dead pane's status only when `remain-on-exit` is `on` for it, set
on the pane or inherited from its window, before the process exits. Any other
value returns `remain_on_exit_required` for a live pane. The call changes no
option. While it waits it registers one `pane-died` hook entry at a private
index and a private `wait-for` channel. The hook is registered and the pane
checked in one tmux command sequence, so an exit cannot fall between them.
Keep the endpoint open through the call's attempt to remove the hook. The
wait result reports the pane outcome. It carries no hook cleanup receipt.

`deadline_ms` bounds the wait; an expired wait returns the operation's
`deadline` error and the pane stays usable for another call. A pane killed or
destroyed meanwhile returns `target_gone`. With `remain-on-exit` set to `on`,
the PTY may close before tmux publishes the exit status or signal. The wait
continues until tmux reports the exit or the deadline expires. Other dead
panes without a published exit return `exit_status_unavailable`.

A returned exit does not prove that the program's output reached the pane;
a job that needs its output captured acknowledges terminal parsing first, as
the [job guide](jobs.md) shows. Calling this on an invalid option fails before
any I/O:

```erlang
1> tmux_pane:wait_exit(invalid_row, #{deadline_ms => 0}).
{error,#{code => invalid_option,path => [deadline_ms]}}
```
""".
-spec wait_exit(tmux_model:pane(), wait_exit_options()) ->
    {ok, wait_exit_result()} | {error, map()}.
wait_exit(Pane, Options) ->
    maybe
        {ok, Deadline} ?= exit_deadline(Options),
        {ok, Server, Target} ?= tmux_target:resolve(pane, Pane),
        {ok, State} ?= exit_state(Server, Target),
        {ok, Outcome} ?= case State of
            {exited, Ended} -> {ok, Ended};
            awaiting_exit -> await_exit(Server, Target, Deadline)
        end,
        {ok, Current} ?= get(Server, tmux_model:get(id, Pane)),
        {ok, #{exit => Outcome, pane => Current}}
    end.

exit_deadline(Options) when is_map(Options) ->
    case maps:keys(maps:without([deadline_ms], Options)) of
        [] ->
            case maps:get(deadline_ms, Options, 30000) of
                Milliseconds when is_integer(Milliseconds, 1, 600000) -> {ok, Milliseconds};
                _ -> {error, #{code => invalid_option, path => [deadline_ms]}}
            end;
        Unknown -> {error, #{code => unknown_option, path => [hd(lists:sort(Unknown))]}}
    end;
exit_deadline(_) -> {error, #{code => invalid_options, path => []}}.

exit_state(Server, Target) ->
    Format = <<"#{pane_id}\t#{pane_dead}\t#{remain-on-exit}\t",
               "#{pane_dead_status}\t#{pane_dead_signal}">>,
    maybe
        {ok, #{stdout := Output}} ?= tmux_target:run(Server, <<"display-message">>,
            [<<"-p">>, <<"-t">>, Target, <<"-F">>, Format], #{max_stdout => 256}),
        [Line, <<>>] ?= binary:split(Output, <<"\n">>),
        parse_exit_state(Target, binary:split(Line, <<"\t">>, [global]))
    else
        Mismatch when not is_tuple(Mismatch); element(1, Mismatch) =/= error ->
            {error, #{code => invalid_pane_state}};
        {error, _} = Error -> Error
    end.

%% display-message tolerates a missing target and prints empty fields.
parse_exit_state(_, [<<>>, _, _, _, _]) -> {error, #{code => target_gone}};
parse_exit_state(Target, [Target, <<"1">>, <<"on">>, <<>>, <<>>]) -> {ok, awaiting_exit};
parse_exit_state(Target, [Target, <<"1">>, _, Status, Signal]) -> parse_exit(Status, Signal);
parse_exit_state(Target, [Target, <<"0">>, <<"on">>, _, _]) -> {ok, awaiting_exit};
parse_exit_state(Target, [Target, <<"0">>, Retention, _, _]) ->
    {error, #{code => remain_on_exit_required, remain_on_exit => Retention}};
parse_exit_state(_, _) -> {error, #{code => invalid_pane_state}}.

parse_exit(<<>>, <<>>) -> {error, #{code => exit_status_unavailable}};
parse_exit(Status, <<>>) ->
    try binary_to_integer(Status) of
        Code when is_integer(Code, 0, 255) -> {ok, {exited, {status, Code}}};
        _ -> {error, #{code => invalid_pane_state}}
    catch error:badarg -> {error, #{code => invalid_pane_state}}
    end;
parse_exit(<<>>, Signal) ->
    try binary_to_integer(Signal) of
        Number when Number > 0 -> {ok, {exited, {signal, Number}}};
        _ -> {error, #{code => invalid_pane_state}}
    catch error:badarg -> {ok, {exited, {signal, Signal}}}
    end;
parse_exit(_, _) -> {error, #{code => invalid_pane_state}}.

await_exit(Server, Target, Deadline) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    Channel = <<"libtmux-exit-", Suffix/binary>>,
    Hook = <<"pane-died[", (integer_to_binary(1000000000 + rand:uniform(1000000000)))/binary, "]">>,
    maybe
        {ok, Wait} ?= tmux_command:wait_for(Channel, wait),
        {ok, Operation} ?= tmux_operation:start(Server, Wait, #{deadline_ms => Deadline}),
        try
            maybe
                ok ?= signal_on_exit(Server, Target, Channel, Hook),
                {ok, _} ?= tmux_operation:await(Operation, infinity),
                {ok, State} ?= exit_state(Server, Target),
                case State of
                    {exited, Outcome} -> {ok, Outcome};
                    awaiting_exit -> {error, #{code => exit_not_observed}}
                end
            end
        after
            _ = tmux_operation:cancel(Operation),
            _ = tmux_operation:await(Operation, 900),
            _ = tmux_target:run(Server, <<"set-hook">>,
                [<<"-p">>, <<"-u">>, <<"-t">>, Target, <<"--">>, Hook])
        end
    end.

%% Register and check published status together, including an exit status of 0.
signal_on_exit(Server, Target, Channel, Hook) ->
    Signal = <<"wait-for -S ", Channel/binary>>,
    Ready = <<"#{&&:#{pane_dead},",
              "#{||:#{!=:#{pane_dead_status},},#{!=:#{pane_dead_signal},}}}">>,
    maybe
        {ok, Set} ?= tmux_command:raw(<<"set-hook">>,
            [<<"-p">>, <<"-t">>, Target, <<"--">>, Hook, Signal]),
        {ok, Check} ?= tmux_command:raw(<<"if-shell">>,
            [<<"-F">>, <<"-t">>, Target, <<"--">>, Ready, Signal]),
        {ok, Sequence} ?= tmux_command:sequence([Set, Check]),
        {ok, _} ?= tmux_target:submit(Server, Sequence, #{}),
        ok
    end.

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
        {ok, Command} ?= resize_command(Pane, Options),
        tmux_target:execute(Command)
    end.

-doc """
Build a resize command without tmux I/O. Uses the dimensions and validation
rules of `resize/2`, preserving the row's captured origin and stable pane ID.
Endpoint liveness and native layout constraints are checked during execution.
Submit through `tmux_server:command/3` or `tmux_operation:start/3`.

```erlang
1> tmux_pane:resize_command(invalid_row, #{}).
{error,#{code => empty_resize}}
```
""".
-spec resize_command(tmux_model:pane(), resize_options()) -> {ok, tmux_command:t()} | {error, map()}.
resize_command(Pane, Options) ->
    maybe
        {ok, Flags} ?= tmux_args:options(Options,
            [{width, dimension, <<"-x">>}, {height, dimension, <<"-y">>}]),
        ok ?= case Flags of [] -> {error, #{code => empty_resize}}; _ -> ok end,
        {ok, Origin, Target} ?= tmux_target:captured_target(pane, Pane),
        tmux_command:generated(pane_resize, Origin, Flags ++ [<<"-t">>, Target])
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

-doc "Wait for literal bytes on a live owned pane. See `tmux_pane_text:start/3` for limits and cancellation.".
-spec wait_for_text(tmux_model:pane(), binary(), tmux_pane_text:options()) ->
    tmux_pane_text:result().
wait_for_text(Pane, Needle, Options) -> tmux_pane_text:wait(Pane, Needle, Options).

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
