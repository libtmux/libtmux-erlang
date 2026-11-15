-module(helper_child).
-moduledoc """
Child programs for the helper protocol suite.

`command/2` builds the argv that starts one program in a fresh Erlang VM. The
helper starts its child without a PATH, so a mode that runs another program
takes that program's path as an argument.
""".
-export([command/2, main/1]).

-doc "The VM binary and its arguments for one mode.".
-spec command(binary(), [binary()]) -> {binary(), [binary()]}.
command(Mode, Arguments) ->
    Erl = list_to_binary(os:find_executable("erl")),
    Directory = list_to_binary(filename:dirname(code:which(?MODULE))),
    {Erl, [<<"+S">>, <<"1:1">>, <<"-noshell">>, <<"-noinput">>, <<"-pa">>, Directory,
           <<"-run">>, <<"helper_child">>, <<"main">>, Mode | Arguments]}.

-spec main([string()]) -> no_return().
main([Mode | Arguments]) ->
    try run(Mode, Arguments)
    catch Class:Reason:Stack ->
        Text = unicode:characters_to_binary(io_lib:format("~p:~p~n~p~n", [Class, Reason, Stack])),
        ok = emit(2, Text),
        halt(1)
    end.

%% Write the text to standard output and standard error, then exit with the
%% status.
-spec run(string(), [string()]) -> no_return().
run("write", [Stdout, Stderr, Status]) ->
    ok = emit(1, list_to_binary(Stdout)),
    ok = emit(2, list_to_binary(Stderr)),
    halt(list_to_integer(Status));
%% Write hex-encoded bytes to standard output and the text to standard error,
%% then wait.
run("write-then-wait", [StdoutHex, Stderr]) ->
    ok = emit(1, binary:decode_hex(list_to_binary(StdoutHex))),
    ok = emit(2, list_to_binary(Stderr)),
    forever();
%% Start `Setsid Sleep 3600`, a sleeping process in a session of its own, print
%% its OS process ID and wait.
run("session-child", [Setsid, Sleep]) ->
    Port = open_port({spawn_executable, Setsid}, [binary, {args, [Sleep, "3600"]}]),
    {os_pid, Pid} = erlang:port_info(Port, os_pid),
    ok = emit(1, integer_to_binary(Pid)),
    forever().

%% Standard output and error through ports, so every byte value passes through.
-spec emit(1 | 2, iodata()) -> ok.
emit(Descriptor, Data) ->
    Port = open_port({fd, 0, Descriptor}, [binary, out]),
    true = port_command(Port, Data),
    ok.

-spec forever() -> no_return().
forever() -> receive after infinity -> ok end.
