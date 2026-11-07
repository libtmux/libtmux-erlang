-module(tmux_pane).
-moduledoc """
Split and observe panes using explicit I/O and registered physical IDs.

split accepts a pane or a window; a window means its active pane at execution.
Options are direction (horizontal or vertical), size ({cells, N} or
{percent, N}), before, full_size, zoom, cwd, env, launch and detach. It defaults
to a detached vertical split. get returns newly observed fields; existing rows
remain unchanged. Reads span several commands and do not claim atomicity.
Launch and environment options follow tmux_session:create/2.
An absent or zero tmux pane_pid is represented as none. A captured positive
PID is an observation, not a guarantee that the process remains alive.

A successful split followed by a failed observation retains the completed
mutation and command result in its error. kill returns the command result.
Detached or stale references cannot act. All calls perform I/O after validation.

send_text sends up to 2,000 literal bytes, including NUL, in one command using
tmux's hexadecimal key form. It adds no Enter key and never splits a large
input into partially applied commands. send_keys accepts up to 256 named keys,
single UTF-8 characters, {function, 1..12} and {control, <<Letter>>}. Named keys
are enter, tab, escape, backspace, space, up, down, left, right, home, 'end',
insert, delete, page_up, page_down and back_tab. Terminal modes still govern
how input is consumed; command completion does not mean a program processed it.

capture returns stdout bytes unchanged, including final newlines. Options are
start and 'end' (line integers or all), join_lines, escape_sequences,
escape_control, retain_trailing_spaces, alternate, pending and quiet. Defaults
are tmux's current-screen capture without escapes, joined wraps or padding.
The endpoint's output limit applies; an oversized capture returns an error.
""".
-export([split/2, get/2, kill/1, send_text/2, send_keys/2, capture/2]).

-spec split(tmux_model:pane() | tmux_model:window(), map()) ->
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

-spec get(tmux_server:t(), tmux_model:pane_id()) -> {ok, tmux_model:pane()} | {error, map()}.
get(Server, Id) -> tmux_observe:get(Server, pane, Id).

-spec kill(tmux_model:pane()) -> {ok, map()} | {error, map()}.
kill(Pane) -> tmux_target:act(pane, Pane, <<"kill-pane">>, []).

-spec send_text(tmux_model:pane(), binary()) -> {ok, map()} | {error, map()}.
send_text(Pane, Bytes) when is_binary(Bytes), byte_size(Bytes) =< 2000 ->
    Hex = [integer_to_binary(Byte, 16) || <<Byte>> <= Bytes],
    send(Pane, [<<"-H">>], Hex);
send_text(_, Bytes) when is_binary(Bytes) -> {error, #{code => command_limit}};
send_text(_, _) -> {error, #{code => invalid_text}}.

-spec send_keys(tmux_model:pane(), [atom() | binary() | tuple()]) -> {ok, map()} | {error, map()}.
send_keys(Pane, Keys) ->
    maybe
        {ok, Arguments} ?= keys(Keys, 256, []),
        send(Pane, [], Arguments)
    end.

-spec capture(tmux_model:pane(), map()) -> {ok, binary()} | {error, map()}.
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
