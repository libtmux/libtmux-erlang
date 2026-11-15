-module(check_release_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

-define(ASSERT_FAILS(Text, Expression),
        ?assertError({release, Text}, Expression)).

tag_matches_semver_exactly_test() ->
    lists:foreach(fun(Version) ->
        ?assertEqual(Version, check_release:validate_version(Version, "v" ++ Version))
    end, ["0.0.1", "0.1.0-alpha.1", "1.0.0"]),
    lists:foreach(fun({Version, Tag}) ->
        ?assertError({release, _}, check_release:validate_version(Version, Tag))
    end, [{"0.0.0+development", "v0.0.0+development"}, {"01.0.0", "v01.0.0"},
          {"0.0.1", "v0.0.2"}, {"0.0.1", "refs/heads/master"},
          {"0.0.1-alpha.01", "v0.0.1-alpha.01"}]),
    ?assertEqual("0.0.1", check_release:validate_version("0.0.1", none)).

checkout_test_() ->
    {setup,
     fun() -> {ok, _} = application:ensure_all_started(libtmux_erlang) end,
     fun(_) -> ok = application:stop(libtmux_erlang) end,
     fun tag_must_resolve_to_clean_checkout/0}.

tag_must_resolve_to_clean_checkout() ->
    script_util:with_tmp_dir("erlang-release-test", fun(Directory) ->
        Root = unicode:characters_to_binary(Directory),
        Git = fun(Arguments) -> script_util:run_ok("git", Arguments, #{cwd => Root}) end,
        Commit = fun(Message) ->
            Git(["-c", "user.name=Release Test", "-c", "user.email=test@example.invalid",
                 "commit", "--quiet", "-m", Message])
        end,
        Git(["init", "--quiet"]),
        ok = file:write_file(filename:join(Directory, "source"), "first"),
        Git(["add", "source"]),
        Commit("fixture"),
        Git(["tag", "v0.0.1"]),
        Head = check_release:validate_checkout(Directory, "v0.0.1"),
        ?assertEqual(Head, check_release:validate_checkout(Directory, none)),
        ok = file:write_file(filename:join(Directory, "source"), "dirty"),
        ?ASSERT_FAILS("release requires a clean checkout",
            check_release:validate_checkout(Directory, "v0.0.1")),
        ok = file:write_file(filename:join(Directory, "untracked"), "x"),
        Git(["add", "source", "untracked"]),
        Commit("second"),
        ?ASSERT_FAILS("release tag must point to HEAD",
            check_release:validate_checkout(Directory, "v0.0.1")),
        ?ASSERT_FAILS("release tag must point to HEAD",
            check_release:validate_checkout(Directory, "v9.9.9")),
        ok = file:write_file(filename:join(Directory, "stray"), "x"),
        ?ASSERT_FAILS("release requires a clean checkout",
            check_release:validate_checkout(Directory, none))
    end).

registry_absence_is_distinct_from_failure_and_mismatch_test() ->
    Expected = <<"qualified source artifact">>,
    Reply = fun(Result) -> fun(_) -> Result end end,
    ?assert(check_release:published_artifact("0.0.1", Expected,
        Reply({ok, 200, Expected}))),
    ?ASSERT_FAILS("public Hex artifact differs from the qualified source package",
        check_release:published_artifact("0.0.1", Expected, Reply({ok, 200, <<"other">>}))),
    ?assertNot(check_release:published_artifact("0.0.1", Expected, Reply({ok, 404, <<>>}))),
    lists:foreach(fun(Status) ->
        ?assertError({release, _},
            check_release:published_artifact("0.0.1", Expected, Reply({ok, Status, <<>>})))
    end, [403, 500]),
    ?assertError({release, _},
        check_release:published_artifact("0.0.1", Expected, Reply({error, econnrefused}))),
    Self = self(),
    check_release:published_artifact("0.0.2", Expected,
        fun(Url) -> Self ! {url, Url}, {ok, 404, <<>>} end),
    ?assertEqual("https://repo.hex.pm/tarballs/libtmux_erlang-0.0.2.tar",
                 receive {url, Url} -> Url end).

qualification_must_bind_the_same_clean_commit_and_bytes_test() ->
    Proof = #{<<"result">> => <<"PASS">>,
              <<"source">> => #{<<"head">> => <<"commit">>, <<"status">> => <<>>},
              <<"packages">> => #{<<"libtmux_erlang">> => #{<<"sha256">> => <<"digest">>}}},
    ?assertEqual(ok, check_release:validate_qualification(Proof, "commit", <<"digest">>)),
    lists:foreach(fun({Head, Digest}) ->
        ?assertError({release, _}, check_release:validate_qualification(Proof, Head, Digest))
    end, [{"other", <<"digest">>}, {"commit", <<"other">>}]),
    Dirty = Proof#{<<"source">> := #{<<"head">> => <<"commit">>,
                                     <<"status">> => <<" M src/changed.erl">>}},
    ?assertError({release, _}, check_release:validate_qualification(Dirty, "commit", <<"digest">>)),
    Failed = Proof#{<<"result">> := <<"FAIL">>},
    ?assertError({release, _}, check_release:validate_qualification(Failed, "commit", <<"digest">>)),
    ?assertError({release, _}, check_release:validate_qualification(#{}, "commit", <<"digest">>)).

application_version_is_the_literal_vsn_test() ->
    script_util:with_tmp_dir("erlang-release-vsn", fun(Directory) ->
        Source = filename:join([Directory, "apps", "libtmux_erlang", "src"]),
        ok = filelib:ensure_path(Source),
        Resource = filename:join(Source, "libtmux_erlang.app.src"),
        ok = file:write_file(Resource, "{application, libtmux_erlang, [\n {vsn, \"0.0.1\"}\n]}.\n"),
        ?assertEqual("0.0.1", check_release:application_version(Directory)),
        ok = file:write_file(Resource, "{application, libtmux_erlang, [{vsn, git}]}.\n"),
        ?ASSERT_FAILS("missing literal application version",
            check_release:application_version(Directory))
    end).
