-module(check_source_package_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(REQUIRED, ["LICENSE", "CHANGELOG.md", "README.md", "rebar.config", "capabilities.json", "assets/logo.svg",
                   "assets/logo-128.png", "assets/logo-512.png", "src/libtmux_erlang.app.src",
                   "c_src/owned_io.c", "c_src/Makefile", "c_src/LICENSE",
                   "c_src/provenance.json"]).

%% Package contents

complete_package_is_accepted_test() ->
    with_tmp(fun(Temp) ->
        Names = ?REQUIRED ++ ["src/libtmux_erlang.erl", "src/near_miss.erlbeam"],
        Path = hex_tarball(Temp, Names),
        ?assertEqual(#{sha256 => script_util:sha256_hex({file, Path}),
                       files => [list_to_binary(Name) || Name <- Names]},
                     check_source_package:check_contents(Path, "libtmux_erlang"))
    end).

prebuilt_files_are_rejected_test() ->
    with_tmp(fun(Temp) ->
        lists:foreach(fun(Prebuilt) ->
            Path = hex_tarball(Temp, ?REQUIRED ++ [Prebuilt]),
            assert_failed("prebuilt files in libtmux_erlang", Prebuilt,
                fun() -> check_source_package:check_contents(Path, "libtmux_erlang") end)
        end, ["priv/tmux_owned_io", "ebin/libtmux_erlang.app", "_build/default/x",
              "src/tmux_a.beam", "c_src/owned_io.o", "lib/helper.so"])
    end).

each_required_file_is_required_test() ->
    with_tmp(fun(Temp) ->
        lists:foreach(fun(Name) ->
            Path = hex_tarball(Temp, ?REQUIRED -- [Name]),
            assert_failed("missing source-package files", Name,
                fun() -> check_source_package:check_contents(Path, "libtmux_erlang") end)
        end, ?REQUIRED)
    end).

archive_without_contents_is_rejected_test() ->
    with_tmp(fun(Temp) ->
        Path = filename:join(Temp, "empty.tar"),
        {ok, Tar} = erl_tar:open(Path, [write]),
        ok = erl_tar:add(Tar, {"VERSION", <<"3">>}, []),
        ok = erl_tar:close(Tar),
        assert_failed("no contents.tar.gz", "empty.tar",
            fun() -> check_source_package:check_contents(Path, "libtmux_erlang") end)
    end).

%% Package source staging

staged_source_omits_build_output_and_keeps_modes_test() ->
    with_tmp(fun(Temp) ->
        Source = filename:join(Temp, "app"),
        Files = [{"src/a.erl", 8#644}, {"c_src/Makefile", 8#755}, {"priv/x", 8#644},
                 {"ebin/y", 8#644}, {"test/t.erl", 8#644}, {"_build/b", 8#644},
                 {"src/test/skipped.erl", 8#644}],
        lists:foreach(fun({Name, Mode}) ->
            Path = filename:join(Source, Name),
            ok = filelib:ensure_path(filename:dirname(Path)),
            ok = file:write_file(Path, Name),
            ok = file:change_mode(Path, Mode)
        end, Files),
        Stage = filename:join(Temp, "stage"),
        ok = check_source_package:copy_package_source(Source, Stage),
        ?assertEqual({ok, <<"src/a.erl">>}, file:read_file(filename:join(Stage, "src/a.erl"))),
        {ok, #file_info{mode = Mode}} = file:read_file_info(filename:join(Stage, "c_src/Makefile")),
        ?assertEqual(8#755, Mode band 8#777),
        lists:foreach(fun(Name) ->
            ?assertNot(filelib:is_file(filename:join(Stage, Name)), Name)
        end, ["priv", "ebin", "test", "_build", "src/test"])
    end).

%% Tool provisioning

cached_tool_archives_are_not_fetched_test() ->
    with_tmp(fun(Temp) ->
        Pins = [pin(<<"hex_core">>, <<"1.0.0">>, <<"core">>)],
        ok = file:write_file(filename:join(Temp, "hex_core-1.0.0.tar"), <<"core">>),
        Self = self(),
        ok = check_source_package:ensure_pins(Temp, Pins,
            fun(Url) -> Self ! {fetched, Url}, {ok, <<"core">>} end),
        receive {fetched, Url} -> error({fetched, Url})
        after 0 -> ok
        end
    end).

missing_tool_archives_are_fetched_and_kept_test() ->
    with_tmp(fun(Temp) ->
        Pins = [pin(<<"verl">>, <<"1.1.1">>, <<"verl-bytes">>)],
        Self = self(),
        ok = check_source_package:ensure_pins(Temp, Pins,
            fun(Url) -> Self ! {fetched, Url}, {ok, <<"verl-bytes">>} end),
        ?assertEqual({ok, <<"verl-bytes">>}, file:read_file(filename:join(Temp, "verl-1.1.1.tar"))),
        receive {fetched, Url} -> ?assertEqual("https://repo.hex.pm/tarballs/verl-1.1.1.tar", Url)
        after 0 -> error(not_fetched)
        end
    end).

changed_tool_archive_is_replaced_test() ->
    with_tmp(fun(Temp) ->
        Pins = [pin(<<"verl">>, <<"1.1.1">>, <<"good">>)],
        Path = filename:join(Temp, "verl-1.1.1.tar"),
        ok = file:write_file(Path, <<"tampered">>),
        ok = check_source_package:ensure_pins(Temp, Pins, fun(_) -> {ok, <<"good">>} end),
        ?assertEqual({ok, <<"good">>}, file:read_file(Path))
    end).

tool_archive_with_the_wrong_digest_is_rejected_test() ->
    with_tmp(fun(Temp) ->
        Pins = [pin(<<"verl">>, <<"1.1.1">>, <<"good">>)],
        assert_failed("tool checksum mismatch", "verl-1.1.1.tar", fun() ->
            check_source_package:ensure_pins(Temp, Pins, fun(_) -> {ok, <<"evil">>} end)
        end),
        ?assertNot(filelib:is_file(filename:join(Temp, "verl-1.1.1.tar")))
    end).

failed_and_oversized_downloads_are_rejected_test() ->
    with_tmp(fun(Temp) ->
        Pins = [pin(<<"verl">>, <<"1.1.1">>, <<"good">>)],
        assert_failed("cannot download", "verl-1.1.1.tar", fun() ->
            check_source_package:ensure_pins(Temp, Pins, fun(_) -> {error, timeout} end)
        end),
        assert_failed("too large", "verl-1.1.1.tar", fun() ->
            check_source_package:ensure_pins(Temp, Pins,
                fun(_) -> {ok, binary:copy(<<0>>, 8 * 1024 * 1024 + 1)} end)
        end),
        ?assertNot(filelib:is_file(filename:join(Temp, "verl-1.1.1.tar")))
    end).

hex_core_is_unpacked_and_compiled_in_order_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Temp) ->
            Core = filename:join(Temp, "hex_core"),
            ok = filelib:ensure_path(Core),
            ok = file:write_file(filename:join(Core, "stale"), <<"old">>),
            Tarball = outer_tarball(Temp, "core.tar", [
                {"src/safe_erl_term.xrl", <<"Definitions.\nD = [0-9]\nRules.\n{D}+ : "
                    "{token, {integer, TokenLine, list_to_integer(TokenChars)}}.\n"
                    "Erlang code.\n">>},
                {"src/fakehex_a.erl", <<"-module(fakehex_a).\n-export([a/0]).\n"
                    "-callback a() -> ok.\na() -> ok.\n">>},
                {"src/fakehex_b.erl", <<"-module(fakehex_b).\n-behaviour(fakehex_a).\n"
                    "-export([a/0]).\na() -> ok.\n">>}]),
            ok = check_source_package:unpack_core(Tarball, Core),
            ?assertNot(filelib:is_file(filename:join(Core, "stale"))),
            Ebin = filename:join(Core, "ebin"),
            try
                ok = check_source_package:compile_core(Core),
                lists:foreach(fun(Module) ->
                    ?assert(filelib:is_regular(filename:join(Ebin, Module ++ ".beam")), Module)
                end, ["fakehex_a", "fakehex_b", "safe_erl_term"])
            after true = code:del_path(Ebin)
            end
        end)
    end}.

a_warning_in_hex_core_is_an_error_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Temp) ->
            Core = filename:join(Temp, "hex_core"),
            Tarball = outer_tarball(Temp, "core.tar", [
                {"src/safe_erl_term.xrl", <<"Definitions.\nD = [0-9]\nRules.\n{D}+ : "
                    "{token, {integer, TokenLine, list_to_integer(TokenChars)}}.\n"
                    "Erlang code.\n">>},
                {"src/fakehex_c.erl", <<"-module(fakehex_c).\n-export([c/0]).\n"
                    "c() -> Unused = 1, ok.\n">>}]),
            ok = check_source_package:unpack_core(Tarball, Core),
            try
                assert_failed("cannot compile", "fakehex_c.erl",
                    fun() -> check_source_package:compile_core(Core) end)
            after true = code:del_path(filename:join(Core, "ebin"))
            end
        end)
    end}.

core_archive_without_contents_is_rejected_test() ->
    with_tmp(fun(Temp) ->
        Path = filename:join(Temp, "core.tar"),
        {ok, Tar} = erl_tar:open(Path, [write]),
        ok = erl_tar:add(Tar, {"VERSION", <<"3">>}, []),
        ok = erl_tar:close(Tar),
        assert_failed("no contents.tar.gz", "core.tar",
            fun() -> check_source_package:unpack_core(Path, filename:join(Temp, "core")) end)
    end).

runtime_names_the_otp_release_test() ->
    ?assertMatch(#{<<"otp">> := _, <<"erts">> := _, <<"architecture">> := _},
                 check_source_package:runtime()),
    #{<<"otp">> := Otp} = check_source_package:runtime(),
    ?assertMatch({match, _}, re:run(Otp, "^[0-9]+\\.[0-9]+")).

%% Prepared tools

prepared_tools_must_match_what_prepare_recorded_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        ?assertEqual(ok, check_source_package:verify_prepared(Root, Tools, Pins, Runtime))
    end).

prepared_tools_reject_a_changed_file_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        ok = file:write_file(filename:join([Tools, "hex_core", "src", "hex_core.erl"]), <<"x">>),
        assert_mismatch(Root, Tools, Pins, Runtime)
    end).

prepared_tools_reject_an_added_file_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        ok = file:write_file(filename:join([Tools, "hex_core", "ebin", "extra.beam"]), <<"x">>),
        assert_mismatch(Root, Tools, Pins, Runtime)
    end).

prepared_tools_reject_another_runtime_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        assert_mismatch(Root, Tools, Pins, Runtime#{<<"otp">> => <<"0.0.0">>})
    end).

prepared_tools_reject_changed_pins_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        ok = file:write_file(filename:join([Root, "tools", "package-tool.json"]), <<"{}">>),
        assert_mismatch(Root, Tools, Pins, Runtime)
    end).

prepared_tools_need_the_recorded_manifest_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        ok = file:delete(filename:join(Tools, "prepared.json")),
        assert_mismatch(Root, Tools, Pins, Runtime),
        ok = file:write_file(filename:join(Tools, "prepared.json"), <<"not json">>),
        assert_mismatch(Root, Tools, Pins, Runtime)
    end).

prepared_tools_need_the_compiled_registry_module_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        ok = file:delete(filename:join([Tools, "hex_core", "ebin", "hex_registry.beam"])),
        Manifest = check_source_package:prepared_manifest(Root, Tools, Runtime),
        ok = file:write_file(filename:join(Tools, "prepared.json"),
                             check_package:encode_json(Manifest)),
        assert_mismatch(Root, Tools, Pins, Runtime)
    end).

prepared_tools_need_the_pinned_archives_test() ->
    with_tools(fun(Root, Tools, Pins, Runtime) ->
        ok = file:write_file(filename:join(Tools, "verl-1.1.1.tar"), <<"swapped">>),
        assert_failed("--prepare first", "check_source_package",
            fun() -> check_source_package:verify_prepared(Root, Tools, Pins, Runtime) end),
        ok = file:delete(filename:join(Tools, "verl-1.1.1.tar")),
        assert_failed("--prepare first", "check_source_package",
            fun() -> check_source_package:verify_prepared(Root, Tools, Pins, Runtime) end)
    end).

%% Git identity

source_identity_binds_a_clean_commit_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_own_git(fun(Temp) ->
            _ = git(Temp, ["init", "--quiet"]),
            ok = file:write_file(filename:join(Temp, "tracked"), <<"one">>),
            _ = git(Temp, ["add", "tracked"]),
            _ = git(Temp, ["-c", "user.name=Check Test", "-c", "user.email=check@example.invalid",
                       "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"]),
            Head = string:trim(git(Temp, ["rev-parse", "HEAD"])),
            Clean = check_source_package:source_identity(Temp),
            ?assertMatch(#{head := Head, status := <<>>, index_tree := Tree} when is_binary(Tree),
                         Clean),
            ?assertEqual(string:trim(git(Temp, ["write-tree"])), maps:get(index_tree, Clean)),
            ok = file:write_file(filename:join(Temp, "tracked"), <<"two">>),
            Dirty = check_source_package:source_identity(Temp),
            ?assertEqual(<<"M tracked">>, maps:get(status, Dirty)),
            ok = file:write_file(filename:join(Temp, "untracked"), <<"new">>),
            ?assertEqual(<<"M tracked\n?? untracked">>,
                         maps:get(status, check_source_package:source_identity(Temp)))
        end)
    end}.

source_identity_is_null_outside_a_repository_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_own_git(fun(Temp) ->
            ?assertMatch(#{head := null, index_tree := null, status := null},
                         check_source_package:source_identity(Temp))
        end)
    end}.

%% Repository configuration

repo_config_round_trips_the_url_and_key_test() ->
    with_tmp(fun(Temp) ->
        Url = "http://127.0.0.1:4040",
        Key = <<"-----BEGIN RSA PUBLIC KEY-----\nMIIB\"\\\n-----END RSA PUBLIC KEY-----\n">>,
        File = filename:join(Temp, "rebar.config"),
        ok = file:write_file(File, check_source_package:repo_config(Url, Key)),
        {ok, [{rebar_packages_cdn, Url}, {hex, [{repos, replace, [Repo]}]}]} =
            file:consult(File),
        ?assertEqual(#{name => <<"hexpm">>, repo_url => <<"http://127.0.0.1:4040">>,
                       repo_public_key => Key}, Repo)
    end).

%% Local registry

registry_serves_files_with_an_etag_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        Body = <<"payload", 0, 255>>,
        ok = write(Public, "tarballs/a.tar", Body),
        {Status, Headers, Received} = get(Registry, "/tarballs/a.tar"),
        ?assertEqual(200, Status),
        ?assertEqual(Body, Received),
        ?assertEqual(<<"\"", (script_util:sha256_hex(Body))/binary, "\"">>,
                     maps:get(<<"etag">>, Headers)),
        ?assertEqual(integer_to_binary(byte_size(Body)), maps:get(<<"content-length">>, Headers))
    end).

registry_etag_follows_the_file_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        ok = write(Public, "names", <<"one">>),
        {200, #{<<"etag">> := First}, _} = get(Registry, "/names"),
        ok = write(Public, "names", <<"two">>),
        {200, #{<<"etag">> := Second}, <<"two">>} = get(Registry, "/names"),
        ?assertNotEqual(First, Second)
    end).

registry_records_every_request_path_in_order_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        ok = write(Public, "names", <<"n">>),
        _ = get(Registry, "/names"),
        _ = get(Registry, "/missing"),
        _ = get(Registry, "/names?x=1"),
        ?assertEqual([<<"/names">>, <<"/missing">>, <<"/names?x=1">>],
                     check_source_package:registry_requests(Registry))
    end).

registry_answers_404_for_missing_files_and_directories_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        ok = write(Public, "tarballs/a.tar", <<"a">>),
        ?assertMatch({404, _, _}, get(Registry, "/missing")),
        ?assertMatch({404, _, _}, get(Registry, "/tarballs")),
        ?assertMatch({404, _, _}, get(Registry, "/tarballs/")),
        ?assertMatch({404, _, _}, get(Registry, "/"))
    end).

registry_never_serves_outside_its_directory_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        ok = write(filename:dirname(Public), "secret", <<"secret">>),
        ok = write(Public, "tarballs/a.tar", <<"a">>),
        lists:foreach(fun(Target) ->
            ?assertMatch({404, _, _}, get(Registry, Target), Target)
        end, ["/../secret", "/tarballs/../../secret", "/%2e%2e/secret",
              "/tarballs/%2E%2E/%2E%2E/secret", "/bad%zz", "/tarballs/a%00.tar"]),
        ?assertMatch({200, _, <<"a">>}, get(Registry, "/tarballs/./a.tar"))
    end).

registry_decodes_percent_escapes_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        ok = write(Public, "tarballs/a.b.tar", <<"dot">>),
        ?assertMatch({200, _, <<"dot">>}, get(Registry, "/tarballs/a%2Eb.tar")),
        ?assertEqual([<<"/tarballs/a%2Eb.tar">>], check_source_package:registry_requests(Registry))
    end).

registry_refuses_requests_past_the_limit_test() ->
    with_registry(#{limit => 2}, fun(Registry, Public) ->
        ok = write(Public, "names", <<"n">>),
        ?assertMatch({200, _, _}, get(Registry, "/names")),
        ?assertMatch({404, _, _}, get(Registry, "/other")),
        ?assertMatch({429, _, _}, get(Registry, "/names")),
        ?assertMatch({429, _, _}, get(Registry, "/names")),
        ?assertEqual([<<"/names">>, <<"/other">>], check_source_package:registry_requests(Registry))
    end).

registry_default_limit_is_256_requests_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        ok = write(Public, "names", <<"n">>),
        lists:foreach(fun(_) -> {200, _, _} = get(Registry, "/names") end, lists:seq(1, 256)),
        ?assertMatch({429, _, _}, get(Registry, "/names")),
        ?assertEqual(256, length(check_source_package:registry_requests(Registry)))
    end).

registry_serves_only_get_and_head_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        ok = write(Public, "names", <<"names">>),
        {405, #{<<"allow">> := <<"GET, HEAD">>}, _} =
            exchange(Registry, <<"POST /names HTTP/1.1\r\nContent-Length: 0\r\n\r\n">>),
        ?assertEqual([], check_source_package:registry_requests(Registry)),
        {200, #{<<"content-length">> := <<"5">>}, Body} =
            exchange(Registry, <<"HEAD /names HTTP/1.1\r\n\r\n">>),
        ?assertEqual(<<>>, Body),
        ?assertEqual([<<"/names">>], check_source_package:registry_requests(Registry))
    end).

registry_rejects_a_malformed_request_test() ->
    with_registry(#{}, fun(Registry, _Public) ->
        ?assertMatch({400, _, _}, exchange(Registry, <<"nonsense\r\n\r\n">>)),
        ?assertEqual([], check_source_package:registry_requests(Registry))
    end).

registry_answers_concurrent_clients_test() ->
    with_registry(#{}, fun(Registry, Public) ->
        Body = binary:copy(<<"x">>, 600000),
        ok = write(Public, "big", Body),
        Self = self(),
        Pids = [spawn_link(fun() -> Self ! {self(), get(Registry, "/big")} end)
                || _ <- lists:seq(1, 8)],
        lists:foreach(fun(Pid) ->
            receive {Pid, Reply} -> ?assertMatch({200, _, Body}, Reply) end
        end, Pids),
        ?assertEqual(8, length(check_source_package:registry_requests(Registry)))
    end).

registry_stops_cleanly_test() ->
    with_tmp(fun(Temp) ->
        Registry = check_source_package:start_registry(Temp, #{}),
        Port = port(Registry),
        ?assertMatch({404, _, _}, get(Registry, "/x")),
        ?assertEqual({[<<"/x">>], true}, check_source_package:stop_registry(Registry)),
        ?assertEqual({error, econnrefused}, gen_tcp:connect({127, 0, 0, 1}, Port, [])),
        ?assertError({registry_down, _}, check_source_package:registry_requests(Registry))
    end).

registry_stop_closes_idle_connections_test() ->
    with_tmp(fun(Temp) ->
        Registry = check_source_package:start_registry(Temp, #{}),
        {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, port(Registry), [binary, {active, false}]),
        ok = gen_tcp:send(Socket, <<"GET /partial">>),
        ?assertMatch({_, true}, check_source_package:stop_registry(Registry)),
        ?assertMatch({error, Reason} when Reason =:= closed; Reason =:= econnreset,
                     gen_tcp:recv(Socket, 0, 5000))
    end).

%% The run receipt

failed_run_replaces_the_receipt_and_exits_1_test_() ->
    {setup, fun start/0, fun stop/1, fun() ->
        with_tmp(fun(Root) ->
            lists:foreach(fun(Name) -> ok = write(Root, Name, <<"input">>) end,
                          ["scripts/package/check_source_package.erl",
                           "tools/source_package_registry.escript",
                           "scripts/package/check_package.erl", "scripts/lib/script_util.erl",
                           ".tool-versions"]),
            ok = write(Root, "tools/package-tool.json", <<"{\"packages\": [{\"name\": \"hex_core\","
                " \"version\": \"0.21.1\", \"sha256\": \"00\"}]}">>),
            Output = filename:join([Root, "_build", "source-package-check"]),
            ok = write(Output, "receipt.json", <<"{\"result\": \"PASS\"}">>),
            ?assertEqual(1, check_source_package:run(Root)),
            {ok, Text} = file:read_file(filename:join(Output, "receipt.json")),
            #{<<"result">> := <<"FAIL">>} = Receipt = json:decode(Text),
            ?assertEqual(lists:sort([<<"result">>, <<"platform">>, <<"machine">>, <<"tools">>,
                                     <<"commands">>, <<"source_sha256">>, <<"packages">>,
                                     <<"publication">>, <<"error">>, <<"seconds">>]),
                         lists:sort(maps:keys(Receipt))),
            ?assertNotEqual(nomatch, binary:match(maps:get(<<"error">>, Receipt), <<"--prepare">>)),
            ?assertEqual(<<"UNVERIFIED; local artifacts only">>,
                         maps:get(<<"publication">>, Receipt)),
            ?assertEqual([], maps:get(<<"commands">>, Receipt)),
            ?assertEqual(lists:sort([<<"scripts/package/check_source_package.erl">>,
                                     <<"tools/source_package_registry.escript">>,
                                     <<"scripts/package/check_package.erl">>,
                                     <<"scripts/lib/script_util.erl">>,
                                     <<"tools/package-tool.json">>, <<".tool-versions">>]),
                         lists:sort(maps:keys(maps:get(<<"source_sha256">>, Receipt)))),
            [Attempt] = filelib:wildcard(filename:join(Output, "run-*")),
            ?assertEqual({ok, Text}, file:read_file(filename:join(Attempt, "receipt.json")))
        end)
    end}.

%% Helpers

start() ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    ok.

stop(_) ->
    ok = application:stop(libtmux_erlang).

with_tmp(Fun) ->
    script_util:with_tmp_dir("check-source-package-test", Fun).

assert_failed(Needle, Also, Fun) ->
    try Fun() of
        Result -> error({did_not_fail, Result})
    catch
        error:{check_failed, Message} ->
            ?assertNotEqual(nomatch, binary:match(Message, list_to_binary(Needle)), Message),
            ?assertNotEqual(nomatch, binary:match(Message, list_to_binary(Also)), Message)
    end.

assert_mismatch(Root, Tools, Pins, Runtime) ->
    assert_failed("repeat --prepare", "mismatch",
        fun() -> check_source_package:verify_prepared(Root, Tools, Pins, Runtime) end).

pin(Name, Version, Content) ->
    #{<<"name">> => Name, <<"version">> => Version,
      <<"sha256">> => script_util:sha256_hex(Content)}.

write(Directory, Name, Bytes) ->
    Path = filename:join(Directory, Name),
    ok = filelib:ensure_path(filename:dirname(Path)),
    file:write_file(Path, Bytes).

% A hook or rebase that runs the tests exports GIT_* variables that would redirect git.
with_own_git(Fun) ->
    Names = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CEILING_DIRECTORIES"],
    Saved = [{Name, os:getenv(Name)} || Name <- Names],
    lists:foreach(fun(Name) -> true = os:unsetenv(Name) end, Names),
    try with_tmp(Fun)
    after lists:foreach(fun
        ({_, false}) -> ok;
        ({Name, Value}) -> true = os:putenv(Name, Value)
    end, Saved)
    end.

git(Directory, Arguments) ->
    script_util:run_ok("git", Arguments, #{cwd => list_to_binary(Directory)}).

hex_tarball(Directory, Names) ->
    outer_tarball(Directory, "package.tar", [{Name, <<"x">>} || Name <- Names]).

% A Hex package archive: `VERSION` plus a gzip-compressed `contents.tar.gz` of the members.
outer_tarball(Directory, Name, Members) ->
    Inner = filename:join(Directory, "contents.tar"),
    {ok, Contents} = erl_tar:open(Inner, [write]),
    lists:foreach(fun({Member, Bytes}) -> ok = erl_tar:add(Contents, {Member, Bytes}, []) end,
                  Members),
    ok = erl_tar:close(Contents),
    {ok, Plain} = file:read_file(Inner),
    ok = file:delete(Inner),
    Path = filename:join(Directory, Name),
    {ok, Outer} = erl_tar:open(Path, [write]),
    ok = erl_tar:add(Outer, {"VERSION", <<"3">>}, []),
    ok = erl_tar:add(Outer, {"contents.tar.gz", zlib:gzip(Plain)}, []),
    ok = erl_tar:close(Outer),
    Path.

% Fake prepared tools whose manifest matches what `prepare` would record.
with_tools(Fun) ->
    with_tmp(fun(Root) ->
        Tools = filename:join([Root, "_build", "source-package-tools"]),
        Archives = [{<<"hex_core">>, <<"0.21.1">>, <<"core">>},
                    {<<"verl">>, <<"1.1.1">>, <<"verl">>}],
        Pins = [pin(Name, Version, Bytes) || {Name, Version, Bytes} <- Archives],
        lists:foreach(fun({Name, Version, Bytes}) ->
            ok = write(Tools, binary_to_list(<<Name/binary, "-", Version/binary, ".tar">>), Bytes)
        end, Archives),
        ok = write(Root, "tools/package-tool.json", json:encode(#{packages => Pins})),
        ok = write(Tools, "hex_core/src/hex_core.erl", <<"-module(hex_core).">>),
        ok = write(Tools, "hex_core/ebin/hex_registry.beam", <<"beam">>),
        Runtime = #{<<"otp">> => <<"29.1.2">>, <<"erts">> => <<"17.1.1">>,
                    <<"architecture">> => <<"x86_64-pc-linux-gnu">>},
        Manifest = check_source_package:prepared_manifest(Root, Tools, Runtime),
        ok = write(Tools, "prepared.json", check_package:encode_json(Manifest)),
        Fun(Root, Tools, Pins, Runtime)
    end).

with_registry(Options, Fun) ->
    with_tmp(fun(Temp) ->
        Public = filename:join(Temp, "public"),
        ok = filelib:ensure_path(Public),
        Registry = check_source_package:start_registry(Public, Options),
        try Fun(Registry, Public)
        after {_, true} = check_source_package:stop_registry(Registry)
        end
    end).

port(Registry) ->
    "http://127.0.0.1:" ++ Port = check_source_package:registry_url(Registry),
    list_to_integer(Port).

get(Registry, Target) ->
    exchange(Registry, iolist_to_binary(["GET ", Target, " HTTP/1.1\r\nHost: registry\r\n\r\n"])).

% Send raw request bytes and read the reply until the server closes the connection.
exchange(Registry, Request) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, port(Registry), [binary, {active, false}]),
    ok = gen_tcp:send(Socket, Request),
    Reply = receive_all(Socket, <<>>),
    [Head, Body] = binary:split(Reply, <<"\r\n\r\n">>),
    [<<"HTTP/1.1 ", Code:3/binary, _/binary>> | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    Headers = maps:from_list([begin
        [Name, Value] = binary:split(Line, <<": ">>),
        {string:lowercase(Name), Value}
    end || Line <- Lines]),
    {binary_to_integer(Code), Headers, Body}.

receive_all(Socket, Received) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> receive_all(Socket, <<Received/binary, Data/binary>>);
        {error, closed} -> Received
    end.
