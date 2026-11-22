-module(check_package_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(APP, "libtmux_erlang").
-define(SESSION_VARIABLES, ["ERL_LIBS", "TMUX", "TMUX_PANE",
                            "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH"]).
-define(REBAR_VARIABLES, ["ERL_LIBS", "TMUX", "TMUX_PANE", "REBAR_CONFIG", "HEX_API_KEY",
                          "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH",
                          "HEX_CDN", "HEX_UNSAFE_REGISTRY", "HEX_NO_VERIFY_REPO_ORIGIN",
                          "HEX_TRUSTED_MIRROR_URL", "HEX_MIRROR_URL"]).

archive_lists_members_in_order_test() ->
    with_root(fun(Root, _Temp) ->
        Names = [Name || {Name, _, _} <- package_archive:members(Root, ?APP)],
        ?assertEqual(["ebin/libtmux_erlang.app", "ebin/tmux_a.beam", "LICENSE",
                      "CHANGELOG.md", "priv/owned_io.LICENSE", "priv/tmux_owned_io"], Names)
    end).

archive_orders_nested_priv_files_by_path_component_test() ->
    with_root(fun(Root, _Temp) ->
        Priv = filename:join([Root, "_build/default/lib", ?APP, "priv"]),
        ok = filelib:ensure_path(filename:join(Priv, "sub")),
        ok = file:write_file(filename:join([Priv, "sub", "x"]), <<"x">>),
        ok = file:write_file(filename:join(Priv, "sub.txt"), <<"t">>),
        Names = [Name || {Name, _, _} <- package_archive:members(Root, ?APP)],
        ?assertEqual(["priv/owned_io.LICENSE", "priv/sub/x", "priv/sub.txt",
                      "priv/tmux_owned_io"], lists:nthtail(4, Names))
    end).

archive_is_deterministic_test() ->
    with_root(fun(Root, Temp) ->
        {First, Prefix} = assemble(Root, Temp, "first"),
        ok = file:write_file_info(source(Root, "LICENSE"),
                                  #file_info{mtime = {{2001, 1, 1}, {0, 0, 0}}}),
        {Second, Prefix} = assemble(Root, Temp, "second"),
        ?assertEqual(read(First), read(Second)),
        ?assertEqual("libtmux_erlang-0.0.0+development", Prefix),
        {ok, Members} = erl_tar:table(First, [compressed]),
        ?assertEqual([Prefix ++ "/ebin/libtmux_erlang.app", Prefix ++ "/ebin/tmux_a.beam",
                      Prefix ++ "/LICENSE", Prefix ++ "/CHANGELOG.md",
                      Prefix ++ "/priv/owned_io.LICENSE", Prefix ++ "/priv/tmux_owned_io"],
                     Members)
    end).

archive_changes_with_its_inputs_test() ->
    with_root(fun(Root, Temp) ->
        {First, _} = assemble(Root, Temp, "first"),
        ok = file:write_file(source(Root, "LICENSE"), <<"changed">>),
        {Second, _} = assemble(Root, Temp, "second"),
        ?assertNotEqual(read(First), read(Second))
    end).

archive_keeps_the_executable_bit_test() ->
    with_root(fun(Root, Temp) ->
        {Archive, Prefix} = assemble(Root, Temp, "archive"),
        Out = filename:join(Temp, "out"),
        ok = file:make_dir(Out),
        ok = package_archive:extract(Archive, Out),
        Mode = fun(Name) ->
            {ok, #file_info{mode = M}} = file:read_file_info(filename:join([Out, Prefix, Name])),
            M band 8#777
        end,
        ?assertEqual(8#755, Mode("priv/tmux_owned_io")),
        ?assertEqual(8#644, Mode("ebin/tmux_a.beam")),
        ?assertEqual(8#644, Mode("LICENSE")),
        ?assertEqual(<<"beam">>, read(filename:join([Out, Prefix, "ebin", "tmux_a.beam"])))
    end).

uncompiled_application_is_rejected_test() ->
    with_root(fun(Root, Temp) ->
        Ebin = filename:join([Root, "_build/default/lib", ?APP, "ebin"]),
        ok = file:del_dir_r(Ebin),
        assert_failed("rebar3 compile first", fun() -> assemble(Root, Temp, "none") end),
        ok = file:make_dir(Ebin),
        assert_failed("rebar3 compile first", fun() -> assemble(Root, Temp, "empty") end),
        ok = file:write_file(filename:join(Ebin, "tmux_a.beam"), <<"beam">>),
        assert_failed("rebar3 compile first", fun() -> assemble(Root, Temp, "beam") end)
    end).

missing_package_text_is_rejected_test() ->
    with_root(fun(Root, Temp) ->
        ok = file:delete(source(Root, "CHANGELOG.md")),
        assert_failed("CHANGELOG.md", fun() -> assemble(Root, Temp, "x") end)
    end).

consumer_sources_exist_test() ->
    Root = repo_root(),
    Missing = [Source || {Source, _} <- check_package:consumer_files(),
                         not filelib:is_regular(filename:join(Root, Source))],
    ?assertEqual([], Missing).

stage_consumer_copies_every_file_test() ->
    Root = repo_root(),
    script_util:with_tmp_dir("check-package-stage", fun(Temp) ->
        ok = check_package:stage_consumer(Root, Temp),
        lists:foreach(fun({Source, Destination}) ->
            ?assertEqual(read(filename:join(Root, Source)), read(filename:join(Temp, Destination)))
        end, check_package:consumer_files()),
        ?assertMatch(<<"-module(tmux_model).\n", _/binary>>,
                     read(filename:join([Temp, "legacy", "tmux_model.erl"]))),
        ?assert(filelib:is_dir(filename:join(Temp, "consumer-ebin")))
    end).

stage_consumer_rejects_a_missing_source_test() ->
    with_root(fun(Root, Temp) ->
        assert_failed("native_consumer.erl",
                      fun() -> check_package:stage_consumer(Root, Temp) end)
    end).

stage_consumer_rejects_a_used_directory_test() ->
    script_util:with_tmp_dir("check-package-stage", fun(Temp) ->
        ok = file:make_dir(filename:join(Temp, "examples")),
        ?assertError({badmatch, {error, eexist}}, check_package:stage_consumer(repo_root(), Temp))
    end).

dialyzer_needs_a_table_before_anything_runs_test() ->
    with_root(fun(Root, Temp) ->
        assert_failed("rebar3 dialyzer first", fun() ->
            check_package:exercise_consumer(Root, filename:join(Temp, "absent"),
                                            filename:join(Temp, "ebin"), #{dialyzer => true})
        end)
    end).

installed_commands_keep_their_contract_test() ->
    Temp = "/t/consumer",
    Ebin = Temp ++ "/_build/default/lib/libtmux_erlang/ebin",
    Commands = check_package:consumer_commands(Temp, Ebin),
    ?assertEqual([json, plain, plain, plain, plain, plain, plain],
                 [Kind || {Kind, _} <- Commands]),
    Plain = [Command || {_, Command} <- Commands],
    ?assertEqual(["escript", "scripts/check/run_examples.escript", "--ebin", Ebin], hd(Plain)),
    ?assert(lists:member([Temp ++ "/_build/default/lib/libtmux_erlang/priv/tmux_owned_io",
                          "--exec-one", "/bin/true"], Plain)),
    ?assert(lists:any(fun(Command) ->
        lists:member("./_build/default/lib/libtmux_erlang/ebin", Command)
    end, Plain)).

installed_commands_need_an_ebin_inside_the_consumer_test() ->
    assert_failed("is not inside", fun() ->
        check_package:consumer_commands("/t/consumer", "/elsewhere/ebin")
    end).

dialyzer_commands_use_the_table_and_installed_beams_test() ->
    [{plain, Dialyzer}, {json, Types}] =
        check_package:dialyzer_commands("/t/c", "/t/c/ebin", "/plt/x_plt"),
    ?assertEqual(["dialyzer", "--plt", "/plt/x_plt"], lists:sublist(Dialyzer, 3)),
    ?assertEqual(["-r", "/t/c/ebin"], lists:nthtail(length(Dialyzer) - 2, Dialyzer)),
    ?assertEqual(["escript", "scripts/package/check_model_types.escript", "/t/c/ebin", "/plt/x_plt",
                  "/t/c/type-consumer"], Types).

consumer_env_removes_session_variables_test() ->
    Env = check_package:consumer_env("/t/c", "/opt/tmux"),
    lists:foreach(fun(Name) -> ?assertEqual(false, maps:get(list_to_binary(Name), Env), Name) end,
                  ?SESSION_VARIABLES),
    ?assertEqual(<<"/opt/tmux">>, maps:get(<<"LIBTMUX_TEST_TMUX">>, Env)),
    ?assertEqual(<<"/t/c/erl_crash.dump">>, maps:get(<<"ERL_CRASH_DUMP">>, Env)).

rebar_env_removes_build_and_hex_variables_test() ->
    Env = check_package:rebar_env("/t/config", "/t/cache"),
    lists:foreach(fun(Name) -> ?assertEqual(false, maps:get(list_to_binary(Name), Env), Name) end,
                  ?REBAR_VARIABLES),
    ?assertEqual(<<"/t/config">>, maps:get(<<"REBAR_GLOBAL_CONFIG_DIR">>, Env)),
    ?assertEqual(<<"/t/cache">>, maps:get(<<"REBAR_CACHE_DIR">>, Env)),
    ?assertEqual(<<"/t/cache">>, maps:get(<<"REBAR_GLOBAL_CACHE_DIR">>, Env)).

rebar_env_defaults_erl_flags_test() ->
    with_env([], fun() ->
        true = os:unsetenv("ERL_FLAGS"),
        ?assertEqual(<<"+S 4:4">>,
                     maps:get(<<"ERL_FLAGS">>, check_package:rebar_env("/t/c", "/t/k"))),
        true = os:putenv("ERL_FLAGS", "+S 2:2"),
        ?assertEqual(<<"+S 2:2">>,
                     maps:get(<<"ERL_FLAGS">>, check_package:rebar_env("/t/c", "/t/k")))
    end).

scrubbed_variables_do_not_reach_the_child_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_env(?REBAR_VARIABLES, fun() ->
            Inherited = child_environment(#{}),
            lists:foreach(fun(Name) -> ?assert(has(Inherited, Name), Name) end,
                          ?REBAR_VARIABLES -- ["TMUX", "TMUX_PANE"]),
            Consumer = child_environment(check_package:consumer_env("/t", "/opt/tmux")),
            lists:foreach(fun(Name) -> ?assertNot(has(Consumer, Name), Name) end,
                          ?SESSION_VARIABLES),
            ?assert(has(Consumer, "LIBTMUX_TEST_TMUX")),
            Rebar = child_environment(check_package:rebar_env("/t/config", "/t/cache")),
            lists:foreach(fun(Name) -> ?assertNot(has(Rebar, Name), Name) end,
                          ?REBAR_VARIABLES)
        end)
    end}.

select_tmux_prefers_the_variable_test() ->
    ?assertEqual("/opt/tmux-3.8", check_package:select_tmux("/opt/tmux-3.8", "/usr/bin/tmux")),
    ?assertEqual("/usr/bin/tmux", check_package:select_tmux("", "/usr/bin/tmux")),
    ?assertEqual("/usr/bin/tmux", check_package:select_tmux(false, "/usr/bin/tmux")).

select_tmux_requires_an_absolute_path_test() ->
    Message = "absolute tmux executable",
    assert_failed(Message, fun() -> check_package:select_tmux("tmux", "/usr/bin/tmux") end),
    assert_failed(Message, fun() -> check_package:select_tmux(false, "bin/tmux") end),
    assert_failed(Message, fun() -> check_package:select_tmux(false, false) end).

run_command_test_() ->
    {setup, fun start/0, fun stop/1,
     [fun run_command_records_a_receipt/0,
      fun run_command_decodes_json/0,
      fun run_command_reports_the_output_of_a_failure/0,
      fun run_command_rejects_invalid_json/0,
      fun run_command_rejects_a_missing_program/0]}.

run_command_records_a_receipt() ->
    script_util:with_tmp_dir("check-package-run", fun(Cwd) ->
        Argument = Cwd ++ "/a:/work/repo/b",
        Receipt = check_package:run_command("/work/repo", Cwd, ["printf", Argument], #{}),
        ?assertMatch(#{program := <<"printf">>, exit_status := 0}, Receipt),
        ?assert(is_float(maps:get(seconds, Receipt))),
        ?assertEqual([<<"printf">>, <<"<consumer>/a:<repo>/b">>], maps:get(command, Receipt)),
        ?assertNot(maps:is_key(output, Receipt))
    end).

run_command_decodes_json() ->
    Receipt = check_package:run_command("/r", "/", ["printf", "{\"ok\":[1,true]}"],
                                        #{json => true}),
    ?assertEqual(#{<<"ok">> => [1, true]}, maps:get(output, Receipt)).

run_command_reports_the_output_of_a_failure() ->
    Command = ["cat", "/nonexistent/for/libtmux"],
    Run = fun() -> check_package:run_command("/r", "/", Command, #{}) end,
    assert_failed("cat failed (1)", Run),
    assert_failed("nonexistent/for/libtmux", Run).

run_command_rejects_invalid_json() ->
    assert_failed("invalid JSON", fun() ->
        check_package:run_command("/r", "/", ["printf", "not json"], #{json => true})
    end).

run_command_rejects_a_missing_program() ->
    assert_failed("failed", fun() ->
        check_package:run_command("/r", "/", ["no-such-program-for-libtmux"], #{})
    end).

receipt_keeps_the_published_shape_test() ->
    Receipt = check_package:receipt(<<"abc">>, [#{program => <<"erl">>}], 1.5),
    Keys = [archive_sha256, commands, documentation_examples, hex_source_package,
            installed_helper_adapter, public_borrowed_endpoint, public_command_builders,
            public_control_attachment, public_domain_consumer, public_filter_consumer,
            public_hook_consumer, public_input_consumer, public_layout_consumer,
            public_option_consumer, public_owned_endpoint, public_snapshot_consumer,
            public_tmux_command_api, publication, relative_code_path_child_cwd, result,
            retained_native_model, scope, seconds, temporary_consumer_removed],
    ?assertEqual(lists:sort(Keys), lists:sort(maps:keys(Receipt))),
    ?assertMatch(#{result := <<"PASS">>, archive_sha256 := <<"abc">>, seconds := 1.5,
                   temporary_consumer_removed := true, hex_source_package := <<"UNVERIFIED">>,
                   publication := <<"UNVERIFIED">>}, Receipt),
    ?assertMatch(<<"PARTIAL", _/binary>>, maps:get(public_tmux_command_api, Receipt)),
    Decoded = json:decode(check_package:encode_json(Receipt)),
    ?assertEqual(lists:sort([atom_to_binary(Key) || Key <- Keys]), lists:sort(maps:keys(Decoded))).

json_is_indented_with_a_final_newline_test() ->
    ?assertEqual(<<"{\n  \"a\": [\n    \"x\"\n  ],\n  \"b\": 1,\n  \"c\": null\n}\n">>,
                 check_package:encode_json(#{b => 1, a => [<<"x">>], c => null})).

printable_replaces_invalid_utf8_test() ->
    ?assertEqual(<<"ok ", 195, 169>>, check_package:printable(<<"ok ", 195, 169>>)),
    ?assertEqual(<<"a", 16#FFFD/utf8, "b">>, check_package:printable(<<"a", 255, "b">>)),
    ?assertEqual(<<"a", 16#FFFD/utf8>>, check_package:printable(<<"a", 16#E2, 16#82>>)).

round6_keeps_microseconds_test() ->
    ?assertEqual(1.234568, check_package:round6(1.2345678)),
    ?assertEqual(2.0, check_package:round6(2)).

start() ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    ok.

stop(_) ->
    ok = application:stop(libtmux_erlang).

child_environment(Env) ->
    #{status := 0, stdout := Out} = script_util:run("env", [], #{env => Env}),
    string:split(binary_to_list(Out), "\n", all).

has(Lines, Name) ->
    lists:any(fun(Line) -> lists:prefix(Name ++ "=", Line) end, Lines).

% Set each variable to "leaked", run Fun, then restore every variable it touched.
with_env(Names, Fun) ->
    Saved = [{Name, os:getenv(Name)} || Name <- ["ERL_FLAGS" | Names]],
    lists:foreach(fun(Name) -> true = os:putenv(Name, "leaked") end, Names),
    try Fun()
    after lists:foreach(fun
        ({Name, false}) -> true = os:unsetenv(Name);
        ({Name, Value}) -> true = os:putenv(Name, Value)
    end, Saved)
    end.

assemble(Root, Temp, Name) ->
    Directory = filename:join(Temp, Name),
    ok = file:make_dir(Directory),
    package_archive:assemble(Root, ?APP, Directory).

source(Root, Name) ->
    filename:join([Root, "apps", ?APP, Name]).

read(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Bytes.

assert_failed(Needle, Fun) ->
    try Fun() of
        Result -> error({did_not_fail, Result})
    catch
        error:{check_failed, Message} ->
            ?assertNotEqual(nomatch, binary:match(Message, list_to_binary(Needle)), Message)
    end.

with_root(Fun) ->
    script_util:with_tmp_dir("check-package-test", fun(Temp) ->
        Root = filename:join(Temp, "root"),
        Application = filename:join([Root, "_build/default/lib", ?APP]),
        Files = [{filename:join([Application, "ebin", "libtmux_erlang.app"]), <<"app">>, 8#644},
                 {filename:join([Application, "ebin", "tmux_a.beam"]), <<"beam">>, 8#644},
                 {filename:join([Application, "priv", "tmux_owned_io"]), <<"helper">>, 8#755},
                 {filename:join([Application, "priv", "owned_io.LICENSE"]), <<"mit">>, 8#644},
                 {source(Root, "LICENSE"), <<"license">>, 8#644},
                 {source(Root, "CHANGELOG.md"), <<"changes">>, 8#644}],
        lists:foreach(fun({Path, Bytes, Mode}) ->
            ok = filelib:ensure_path(filename:dirname(Path)),
            ok = file:write_file(Path, Bytes),
            ok = file:change_mode(Path, Mode)
        end, Files),
        Fun(Root, Temp)
    end).

repo_root() ->
    ascend(filename:dirname(code:which(?MODULE))).

ascend(Directory) ->
    case filelib:is_regular(filename:join(Directory, "rebar.config")) of
        true -> Directory;
        false -> ascend(filename:dirname(Directory))
    end.
