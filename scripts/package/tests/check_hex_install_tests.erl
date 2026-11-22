-module(check_hex_install_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

-define(FAILING_REBAR3, ~"""
    #!/usr/bin/env escript
    main(_) ->
        {ok, Config} = file:read_file("rebar.config"),
        Names = ["REBAR_CACHE_DIR", "REBAR_GLOBAL_CONFIG_DIR", "HEX_API_KEY", "ERL_LIBS"],
        Present = [Name ++ "=" || Name <- Names, os:getenv(Name) =/= false],
        io:format(standard_error, "fake rebar3 failure~n~s~n~s~n",
                  [Config, lists:join("\n", Present)]),
        halt(1).
    """).

-define(REBAR3_WITH_HELPER, ~"""
    #!/bin/sh
    set -eu
    mkdir -p _build/default/lib/libtmux_erlang/priv
    touch _build/default/lib/libtmux_erlang/priv/tmux_owned_io
    """).

-define(QUICKSTART_ERL, ~"""
    #!/bin/sh
    set -eu
    test "$3" = "_build/default/lib/libtmux_erlang/ebin"
    test -f quickstart.erl
    printf '{"panes":1}\n'
    """).

invalid_versions_are_rejected_before_any_file_is_written_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Root) ->
            lists:foreach(fun(Version) ->
                assert_failed("SemVer without build metadata",
                              fun() -> check_hex_install:run(Root, Version) end),
                ?assertNot(filelib:is_file(receipt(Root)), Version)
            end, ["0.0.0+development", "01.0.0", "0.0.1-alpha.01", "1.0", "", "0.0.1\n",
                  "v0.0.1", "0.0.1+build.5"])
        end)
    end}.

failed_install_leaves_an_unverified_receipt_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Root) ->
            ok = write(receipt(Root), "{\"result\": \"PASS\"}"),
            with_rebar3(Root, ?FAILING_REBAR3, fun() ->
                assert_failed("fake rebar3 failure",
                              fun() -> check_hex_install:run(Root, "0.1.0-alpha.1") end)
            end),
            {ok, Text} = file:read_file(receipt(Root)),
            ?assertEqual(#{<<"result">> => <<"UNVERIFIED">>, <<"version">> => <<"0.1.0-alpha.1">>,
                           <<"reason">> => <<"public installation started">>},
                         json:decode(Text))
        end)
    end}.

consumer_declares_only_the_release_and_runs_without_hex_credentials_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Root) ->
            true = os:putenv("HEX_API_KEY", "secret-key"),
            true = os:putenv("ERL_LIBS", "/leaked/libs"),
            try with_rebar3(Root, ?FAILING_REBAR3, fun() ->
                Message = failure(fun() -> check_hex_install:run(Root, "0.1.0") end),
                Deps = <<"{deps, [{libtmux_erlang, \"0.1.0\"}]}.">>,
                ?assertNotEqual(nomatch, binary:match(Message, Deps)),
                ?assertNotEqual(nomatch, binary:match(Message, <<"REBAR_CACHE_DIR=">>)),
                ?assertNotEqual(nomatch, binary:match(Message, <<"REBAR_GLOBAL_CONFIG_DIR=">>)),
                ?assertEqual(nomatch, binary:match(Message, <<"HEX_API_KEY">>)),
                ?assertEqual(nomatch, binary:match(Message, <<"ERL_LIBS">>))
            end)
            after true = os:unsetenv("HEX_API_KEY"), true = os:unsetenv("ERL_LIBS")
            end
        end)
    end}.

install_that_builds_no_helper_is_rejected_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Root) ->
            with_rebar3(Root, ~"#!/usr/bin/env escript\nmain(_) -> ok.\n", fun() ->
                assert_failed("did not build the helper",
                              fun() -> check_hex_install:run(Root, "0.1.0") end)
            end),
            {ok, Text} = file:read_file(receipt(Root)),
            ?assertMatch(#{<<"result">> := <<"UNVERIFIED">>}, json:decode(Text))
        end)
    end}.

public_install_runs_the_installed_quickstart_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Root) ->
            ok = write(filename:join([Root, "examples", "quickstart.erl"]), <<>>),
            ok = write_executable(filename:join([Root, "bin", "erl"]), ?QUICKSTART_ERL),
            ok = write_executable(filename:join([Root, "bin", "tmux"]), <<"#!/bin/sh\n">>),
            with_rebar3(Root, ?REBAR3_WITH_HELPER, fun() ->
                ?assertEqual(0, check_hex_install:run(Root, "0.1.0"))
            end),
            {ok, Text} = file:read_file(receipt(Root)),
            ?assertMatch(#{<<"result">> := <<"PASS">>,
                           <<"consumers">> := [#{<<"output">> := #{<<"panes">> := 1},
                                                 <<"owned_cleanup">> := <<"complete">>}],
                           <<"temporary_consumer_removed">> := true}, json:decode(Text))
        end)
    end}.

start() ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    ok.

stop(_) ->
    ok = application:stop(libtmux_erlang).

with_tmp(Fun) ->
    script_util:with_tmp_dir("check-hex-install-test", Fun).

receipt(Root) ->
    filename:join([Root, "_build", "checks", "hex-install.json"]).

write(Path, Text) ->
    ok = filelib:ensure_path(filename:dirname(Path)),
    file:write_file(Path, Text).

write_executable(Path, Text) ->
    ok = write(Path, Text),
    file:change_mode(Path, 8#755).

% Put a fake `rebar3` first on PATH for the duration of Fun.
with_rebar3(Root, Script, Fun) ->
    Bin = filename:join(Root, "bin"),
    ok = write_executable(filename:join(Bin, "rebar3"), Script),
    Path = os:getenv("PATH"),
    true = os:putenv("PATH", Bin ++ ":" ++ Path),
    try Fun()
    after true = os:putenv("PATH", Path)
    end.

failure(Fun) ->
    try Fun() of
        Result -> error({did_not_fail, Result})
    catch error:{check_failed, Message} -> Message
    end.

assert_failed(Needle, Fun) ->
    Message = failure(Fun),
    ?assertNotEqual(nomatch, binary:match(Message, list_to_binary(Needle)), Message).
