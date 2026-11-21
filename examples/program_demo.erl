-module(program_demo).
-moduledoc "Run a literal command, send input and stop a private PTY program.".
-export([run/1]).

-spec run(binary()) -> map().
run(Executable) ->
    % docs:begin run
    Text = <<"build; #{pane_id}">>,
    Argv = [<<"/usr/bin/printf">>, <<"%s\n">>, Text],
    Result = tmux_program:run(Executable, Argv, #{height => 4}),
    % docs:end run
    case Result of
        {ok, #{exit := {status, 0}, screen := Screen, cleanup := complete}} ->
            [Text | _] = binary:split(Screen, <<"\n">>),
            #{literal => Text, interactive => interactive(Executable),
              stopped => stop_program(Executable)};
        {error, #{code := unsupported_capability, capability := program_history,
                  found := Found, required := Required}} ->
            #{found => Found, required => Required}
    end.

interactive(Executable) ->
    Code = <<"IFS= read -r line; printf 'heard %s\\n' \"$line\"">>,
    Argv = [<<"/bin/sh">>, <<"-c">>, Code],
    with_program(Executable, Argv, fun(Program) ->
        % docs:begin input
        {ok, #{state := released}} = tmux_program:await_started(Program, 900),
        {ok, #{bytes := 6}} = tmux_program:send_text(Program, <<"build\n">>),
        {ok, #{exit := {status, 0}, screen := Screen, cleanup := complete}} =
            tmux_program:await(Program, 900),
        % docs:end input
        Line = <<"heard build">>,
        true = lists:member(Line, binary:split(Screen, <<"\n">>, [global])),
        Line
    end).

stop_program(Executable) ->
    with_program(Executable, [<<"/bin/cat">>], fun(Program) ->
        % docs:begin stop
        {ok, #{state := released}} = tmux_program:await_started(Program, 900),
        {error, #{code := await_timeout}} = tmux_program:await(Program, 0),
        {ok, stop_requested} = tmux_program:stop(Program),
        {error, #{code := program_stopped, cleanup := complete}} =
            tmux_program:await(Program, 900),
        % docs:end stop
        complete
    end).

with_program(Executable, Argv, Function) ->
    {ok, Program} = tmux_program:start(Executable, Argv, #{}),
    try Function(Program)
    after
        {ok, _} = tmux_program:stop(Program),
        _ = tmux_program:await(Program, infinity),
        ok = tmux_program:release(Program)
    end.
