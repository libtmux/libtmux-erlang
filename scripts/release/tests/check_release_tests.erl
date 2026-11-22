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

actions_release_only_a_push_names_a_tag_test() ->
    ?assertEqual("v0.0.1", check_release:actions_tag("push", "v0.0.1")),
    lists:foreach(fun(Event) ->
        ?assertEqual(none, check_release:actions_tag(Event, "refs/pull/1/merge"))
    end, ["pull_request", "workflow_dispatch", false]),
    ?assertError(missing_ref_name, check_release:actions_tag("push", false)).

submission_run_must_identify_this_repositories_release_tag_push_test() ->
    Repo = "libtmux/libtmux-erlang",
    Head = binary:copy(<<"a">>, 40),
    Run = #{<<"path">> => <<".github/workflows/release.yml">>,
            <<"event">> => <<"push">>, <<"head_sha">> => Head,
            <<"head_branch">> => <<"v0.0.3">>,
            <<"head_repository">> => #{<<"full_name">> => list_to_binary(Repo)}},
    ?assertEqual(#{tag => <<"v0.0.3">>, head => Head, version => <<"0.0.3">>},
                 check_release:submission(Run, Repo)),
    Invalid = [Run#{<<"path">> := <<".github/workflows/ci.yml">>},
               Run#{<<"event">> := <<"workflow_dispatch">>},
               Run#{<<"head_branch">> := <<"master">>},
               Run#{<<"head_branch">> := <<"v0.0.3\nhead=other">>},
               Run#{<<"head_sha">> := <<"short">>},
               Run#{<<"head_repository">> := #{<<"full_name">> => <<"other/repo">>}}, #{}],
    lists:foreach(fun(Other) ->
        ?assertError({release, _}, check_release:submission(Other, Repo))
    end, Invalid).

submission_run_id_rejects_non_numeric_input_before_a_request_test() ->
    Self = self(),
    Fetch = fun(_) -> Self ! unexpected_request, {error, unexpected_request} end,
    lists:foreach(fun(Id) ->
        ?assertError({release, _}, check_release:submission_run(Id,
            "libtmux/libtmux-erlang", Fetch))
    end, ["", "0", "-1", "1/other", "12\noutput=bad"]),
    receive unexpected_request -> ?assert(false) after 0 -> ok end,
    ?assertError({release, _}, check_release:submission_run("42",
        "libtmux/libtmux-erlang", fun(_) -> {ok, 404, <<>>} end)),
    ?assertError({release, _}, check_release:submission_run("42",
        "libtmux/libtmux-erlang", fun(_) -> {ok, 200, <<"invalid json">>} end)).

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
        _ = Git(["init", "--quiet"]),
        ok = file:write_file(filename:join(Directory, "source"), "first"),
        _ = Git(["add", "source"]),
        _ = Commit("fixture"),
        _ = Git(["tag", "v0.0.1"]),
        Head = check_release:validate_checkout(Directory, "v0.0.1"),
        ?assertEqual(Head, check_release:validate_checkout(Directory, none)),
        ?assertEqual(Head, check_release:validate_checkout(Directory,
            {"v0.0.1", Head})),
        ?ASSERT_FAILS("submitted release run must identify HEAD",
            check_release:validate_checkout(Directory, {"v0.0.1", lists:duplicate(40, $0)})),
        ok = file:write_file(filename:join(Directory, "source"), "dirty"),
        ?ASSERT_FAILS("release requires a clean checkout",
            check_release:validate_checkout(Directory, "v0.0.1")),
        ok = file:write_file(filename:join(Directory, "untracked"), "x"),
        _ = Git(["add", "source", "untracked"]),
        _ = Commit("second"),
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

hexdocs_requires_a_versioned_page_with_status_200_test() ->
    Url = "https://libtmux-erlang.hexdocs.pm/0.0.1/readme.html",
    Fetch = fun(Status) ->
        fun(Requested) ->
            ?assertEqual(Url, Requested),
            {ok, Status, <<>>}
        end
    end,
    ?assertEqual(ok, check_release:verify_hexdocs("0.0.1", Fetch(200))),
    lists:foreach(fun(Status) ->
        ?assertError({release, _}, check_release:verify_hexdocs("0.0.1", Fetch(Status)))
    end, [204, 301, 404]),
    ?assertError({release, _},
        check_release:verify_hexdocs("0.0.1", fun(_) -> {error, timeout} end)),
    Fetched = make_ref(),
    UnexpectedFetch = fun(_) -> self() ! Fetched, {ok, 200, <<>>} end,
    ?assertError({release, _}, check_release:verify_hexdocs("0.0.1+development", UnexpectedFetch)),
    receive Fetched -> ?assert(false) after 0 -> ok end.

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
