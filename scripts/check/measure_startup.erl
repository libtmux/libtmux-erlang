-module(measure_startup).
-mode(compile).
-export([main/1]).

-spec main([string()]) -> ok.
main([Count]) ->
    Samples = list_to_integer(Count),
    true = Samples > 0,
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase)),
    Directory = filename:join(temp_dir(), "erlang-startup-" ++ Suffix),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    try
        Interpret = filename:join(Directory, "interpret.erl"),
        Compile = filename:join(Directory, "compile.erl"),
        Header = <<"#!/usr/bin/env escript\n">>,
        ok = file:write_file(Interpret, [Header, <<"main([]) -> ok.\n">>]),
        ok = file:write_file(Compile, [Header, <<"-mode(compile).\nmain([]) -> ok.\n">>]),
        Result = #{otp => list_to_binary(erlang:system_info(otp_release)),
                   erts => list_to_binary(erlang:system_info(version)),
                   arch => list_to_binary(erlang:system_info(system_architecture)),
                   schedulers => erlang:system_info(schedulers_online),
                   samples => Samples,
                   erl => measure("erl", ["-noshell", "-eval", "halt()."], Samples),
                   interpreted_escript => measure("escript", [Interpret], Samples),
                   compiled_escript => measure("escript", [Compile], Samples),
                   rebar3_version => measure("rebar3", ["version"], Samples)},
        io:format("~s~n", [json:encode(Result)])
    after ok = file:del_dir_r(Directory)
    end.

temp_dir() ->
    case os:getenv("RUNNER_TEMP") of false -> "/tmp"; Path -> Path end.

measure(Program, Arguments, Samples) ->
    Executable = os:find_executable(Program),
    Times = [elapsed(Executable, Arguments) || _ <- lists:seq(1, Samples)],
    Sorted = lists:sort(Times),
    Middle = (lists:nth((Samples + 1) div 2, Sorted)
              + lists:nth(Samples div 2 + 1, Sorted)) / 2,
    #{first_ms => hd(Times), median_ms => Middle,
      min_ms => hd(Sorted), max_ms => lists:last(Sorted), elapsed_ms => Times}.

elapsed(Executable, Arguments) ->
    {Micros, ok} = timer:tc(fun() ->
        Port = open_port({spawn_executable, Executable},
                         [binary, use_stdio, stderr_to_stdout, exit_status, {args, Arguments}]),
        try await(Port, erlang:monotonic_time(millisecond) + 900, [])
        catch error:Reason -> error({filename:basename(Executable), Reason})
        after
            case erlang:port_info(Port) of undefined -> ok; _ -> port_close(Port) end
        end
    end),
    Micros / 1000.

await(Port, Deadline, Output) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Bytes}} -> await(Port, Deadline, [Bytes | Output]);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Status}} ->
            error({launcher_exit, Status, iolist_to_binary(lists:reverse(Output))})
    after Remaining -> error(launcher_timeout)
    end.
