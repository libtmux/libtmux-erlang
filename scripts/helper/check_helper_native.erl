%% Outer check: instrumented helper lifecycle tests and bounded parser fuzzing.
%% Usage: escript scripts/helper/check_helper_native.erl [--cc COMPILER] [--runs N]
%% Needs a Clang with the address, undefined-behavior and fuzzer sanitizers and
%% the compiled library. Writes _build/checks/helper-native/receipt.json.
-module(check_helper_native).
-mode(compile).
-export([main/1, seeds/0, frame/1, flags/0]).

-define(SEED, 20261108).
-define(OUTPUT, "_build/checks/helper-native").

-spec main([string()]) -> no_return().
main(Arguments) ->
    {Compiler, Runs} = options(Arguments, "clang-18", 10000),
    Root = filename:dirname(filename:dirname(filename:dirname(
        filename:absname(escript:script_name())))),
    ok = code:add_pathsa([filename:join(Root, "_build/default/extras/scripts")]),
    ok = script_util:boot(Root),
    ok = filelib:ensure_path(?OUTPUT),
    Attempt = filename:join(?OUTPUT, "run-" ++ integer_to_list(erlang:system_time(nanosecond))),
    ok = filelib:ensure_path(Attempt),
    _ = file:delete(filename:join(?OUTPUT, "receipt.json")),
    put(commands, []),
    Started = erlang:monotonic_time(millisecond),
    Base = #{result => <<"FAIL">>,
             scope => <<"Helper ASan/UBSan lifecycle and parser fuzzing">>,
             attempt => list_to_binary(Attempt),
             platform => list_to_binary(erlang:system_info(system_architecture)),
             machine => string:trim(script_util:run_ok("uname", ["-m"], #{})),
             runs_requested => Runs, seed => ?SEED,
             source_sha256 => maps:from_list([{list_to_binary(Name), script_util:sha256_hex({file, Name})}
                 || Name <- ["apps/libtmux_erlang/c_src/owned_io.c", "test/helper_fuzz.c",
                             "scripts/helper/tests/helper_protocol_SUITE.erl",
                             "scripts/helper/check_helper_native.erl"]])},
    Outcome = try {ok, run(Compiler, Runs, Attempt)}
              catch error:{check_failed, Message} -> {error, Message}
              end,
    Receipt0 = case Outcome of
        {ok, Facts} -> maps:merge(Base#{result := <<"PASS">>}, Facts);
        {error, Message1} -> Base#{error => unicode:characters_to_binary(Message1)}
    end,
    Receipt = Receipt0#{commands => lists:reverse(get(commands)),
                        seconds => (erlang:monotonic_time(millisecond) - Started) / 1000},
    Document = [json:format(Receipt), $\n],
    ok = file:write_file(filename:join(Attempt, "receipt.json"), Document),
    ok = file:write_file(filename:join(?OUTPUT, "receipt.json"), Document),
    io:format("~s", [Document]),
    halt(case Outcome of {ok, _} -> 0; {error, _} -> 1 end).

options([], Compiler, Runs) -> {Compiler, Runs};
options(["--cc", Compiler | Rest], _, Runs) -> options(Rest, Compiler, Runs);
options(["--runs", Text | Rest], Compiler, _) ->
    Runs = list_to_integer(Text),
    (Runs >= 1000 andalso Runs =< 100000) orelse usage("runs must be between 1000 and 100000"),
    options(Rest, Compiler, Runs);
options(_, _, _) -> usage("usage: check_helper_native.erl [--cc COMPILER] [--runs N]").

usage(Message) ->
    io:format(standard_error, "~s~n", [Message]),
    halt(2).

-spec flags() -> [string()].
flags() ->
    ["-O1", "-g", "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
     "-fno-sanitize-recover=all", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic"].

run(Compiler, Runs, Attempt) ->
    Environment = #{<<"ASAN_OPTIONS">> => list_to_binary(
                        "detect_leaks=1:abort_on_error=1:log_path=" ++ Attempt ++ "/asan"),
                    <<"UBSAN_OPTIONS">> => list_to_binary(
                        "halt_on_error=1:print_stacktrace=1:log_path=" ++ Attempt ++ "/ubsan"),
                    <<"TMUX">> => false, <<"TMUX_PANE">> => false},
    Version = hd(string:split(command(Compiler, ["--version"], Environment, Attempt, 30), "\n")),
    script_util:with_tmp_dir("tmux-erlang-native", fun(Temporary) ->
        Helper = filename:join(Temporary, "helper"),
        Fuzzer = filename:join(Temporary, "fuzz"),
        command(Compiler, flags() ++ ["apps/libtmux_erlang/c_src/owned_io.c", "-o", Helper],
                Environment, Attempt, 60),
        Suite = Environment#{<<"LIBTMUX_TEST_HELPER">> => list_to_binary(Helper),
                             <<"LIBTMUX_TEST_CC">> => list_to_binary(Compiler),
                             <<"LIBTMUX_TEST_CFLAGS">> => list_to_binary(string:join(flags(), " "))},
        command("rebar3", ["ct", "--dir", "scripts/helper/tests", "--suite", "helper_protocol_SUITE"],
                Suite, Attempt, 300),
        command(Compiler, flags() ++ ["-fsanitize=fuzzer", "test/helper_fuzz.c", "-o", Fuzzer],
                Environment, Attempt, 60),
        Corpus = filename:join(Temporary, "corpus"),
        ok = file:make_dir(Corpus),
        Initial = seeds(),
        lists:foreach(fun(Seed) ->
            ok = file:write_file(filename:join(Corpus, binary_to_list(script_util:sha256_hex(Seed))), Seed)
        end, Initial),
        {ok, Written} = file:list_dir(Corpus),
        Log = command(Fuzzer, [Corpus, "-runs=" ++ integer_to_list(Runs), "-seed=" ++ integer_to_list(?SEED),
                               "-max_len=65540", "-timeout=1", "-rss_limit_mb=256",
                               "-artifact_prefix=" ++ Attempt ++ "/"], Environment, Attempt, 120),
        Done = "Done " ++ integer_to_list(Runs) ++ " runs",
        string:find(Log, Done) =/= nomatch orelse
            fail("fuzzer did not complete the requested run count"),
        {ok, After} = file:list_dir(Corpus),
        [] =:= filelib:wildcard(filename:join(Attempt, "{asan,ubsan}.*")) orelse
            fail("a sanitizer wrote a report"),
        #{compiler => unicode:characters_to_binary(Version),
          seed_corpus_sha256 => script_util:sha256_hex(iolist_to_binary(lists:sort(Initial))),
          generated_seed_cases => length(Initial),
          initial_corpus_files => length(Written),
          corpus_cases_after => length(After),
          fuzz_scope => <<"Real read_parent/launch/input_packet with fragmented reads and EOF; "
                          "fork returns EAGAIN, so fuzz input never executes a child. "
                          "Separate instrumented protocol tests exercise actual owned children.">>,
          temporary_files_removed => true}
    end).

%% Run one command, keep its output in the attempt directory and record it.
command(Program, Arguments, Environment, Attempt, Seconds) ->
    Result = script_util:run(Program, Arguments,
        #{env => Environment, timeout_ms => Seconds * 1000}),
    Number = length(get(commands)) + 1,
    Log = filename:join(Attempt, "command-" ++ integer_to_list(Number) ++ ".log"),
    #{stdout := Out, stderr := Err, seconds := Elapsed, status := Status} = Result,
    ok = file:write_file(Log, [Out, Err]),
    put(commands, [#{command => [unicode:characters_to_binary(P) || P <- [Program | Arguments]],
                     seconds => Elapsed, exit_status => status(Status),
                     timed_out => Status =:= timeout, log => list_to_binary(Log)}
                   | get(commands)]),
    case Status of
        0 -> unicode:characters_to_list(<<Out/binary, Err/binary>>);
        _ -> fail(lists:flatten(io_lib:format("command failed: ~ts ~ts~n~ts",
                [Program, lists:join(" ", Arguments), tail(<<Out/binary, Err/binary>>)])))
    end.

status(timeout) -> 124;
status(error) -> 127;
status(Code) -> Code.

tail(Text) when byte_size(Text) > 6000 -> binary:part(Text, byte_size(Text) - 6000, 6000);
tail(Text) -> Text.

fail(Message) -> error({check_failed, Message}).

%% The seed corpus: well-formed frames, truncated openings and hostile headers,
%% each under every read-fragmentation mode.
-spec seeds() -> [binary()].
seeds() ->
    Opening = <<"O", 4, 1, 900:32, (string(<<"/tmp">>))/binary, 1:16,
                (string(<<"/bin/true">>))/binary, 0:16>>,
    Bodies = [Opening, <<"Q">>, <<"C">>, <<"T">>, <<"R", 1, 16#20, 0>>,
              <<"R", 2, 16#20, 1>>, <<"W", 0, 0, 0, 1, "hello">>],
    Wires = [frame(Body) || Body <- Bodies] ++
        [frame(binary:part(Opening, 0, Cut)) || Cut <- [0, 1, 6, 8, 12, byte_size(Opening) - 1]] ++
        [<<0>>, <<0, 0>>, <<16#80, 1>>, <<16#ff, 16#ff>>,
         frame(<<"W", 0, 0, 0, 1, (binary:copy(<<"x">>, 8192))/binary>>),
         frame(<<"W", 0, 0, 0, 1, (binary:copy(<<"x">>, 8193))/binary>>),
         binary:copy(frame(<<"R", 1, 16#20, 0>>), 2), binary:copy(frame(<<"C">>), 2),
         frame(binary:copy(<<"x">>, 32768))],
    [<<Mode, Fragment, Wire/binary>> || Mode <- lists:seq(0, 3), Fragment <- [0, 255], Wire <- Wires].

-spec frame(binary()) -> binary().
frame(Body) -> <<(byte_size(Body)):16, Body/binary>>.

string(Value) -> <<(byte_size(Value)):16, Value/binary>>.
