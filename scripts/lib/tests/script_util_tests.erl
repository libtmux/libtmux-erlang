-module(script_util_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

run_test_() ->
    {setup,
     fun() -> {ok, _} = application:ensure_all_started(libtmux_erlang) end,
     fun(_) -> ok = application:stop(libtmux_erlang) end,
     [fun captures_streams_and_status/0,
      fun kills_a_command_past_its_deadline/0,
      fun reports_a_missing_program/0,
      fun run_ok_raises_on_failure/0,
      fun temporary_directory_is_removed/0]}.

captures_streams_and_status() ->
    ?assertMatch(#{status := 7, stdout := <<"out">>, stderr := <<"err">>},
        script_util:run("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"], #{})),
    ?assertEqual(<<"x">>, script_util:run_ok("printf", ["x"], #{})).

kills_a_command_past_its_deadline() ->
    ?assertMatch(#{status := timeout},
        script_util:run("sleep", ["30"], #{timeout_ms => 50})).

reports_a_missing_program() ->
    ?assertMatch(#{status := error, reason := not_found},
        script_util:run("no-such-program-for-libtmux", [], #{})).

run_ok_raises_on_failure() ->
    ?assertError({command_failed, "false", [], _}, script_util:run_ok("false", [], #{})).

temporary_directory_is_removed() ->
    Path = script_util:with_tmp_dir("script-util-test", fun(Directory) ->
        ok = file:write_file(filename:join(Directory, "f"), <<"x">>),
        Directory
    end),
    ?assertEqual({error, enoent}, file:read_file_info(Path)).

sha256_test() ->
    ?assertEqual(<<"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824">>,
                 script_util:sha256_hex(<<"hello">>)).
