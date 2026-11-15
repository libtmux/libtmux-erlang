-module(build_docs_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

-define(EXTRAS, [<<"README.md">>, <<"docs/guide.md">>]).

tree() ->
    [{"README.md", <<"# Title\n\n[guide](docs/guide.md#a) [demo](examples/demo.erl#L2) "
                     "[web](https://example.com/a.md) [top](#title)\n">>},
     {"docs/guide.md", <<"# Guide\n\n![logo](assets/logo.svg)\n">>},
     {"examples/demo.erl", <<"-module(demo).\nrun() -> a < b.\n">>},
     {"docs/assets/logo.svg", <<"<svg/>">>},
     {"docs/assets/a.png", <<"a">>},
     {"docs/assets/b.png", <<"b">>}].

with_repository(Fun) ->
    docs_fixture:with_tree(tree(), fun(Root) ->
        docs_fixture:init_repository(Root),
        Fun(Root, build_docs:context(Root, ?EXTRAS))
    end).

stage(Context, Page) -> build_docs:stage_page(Context, Page, build_docs:new_state()).

failure(Fun) ->
    try Fun() of
        Result -> {passed, Result}
    catch error:{build_docs, Message} -> Message
    end.

read(Root, Path) ->
    {ok, Data} = file:read_file(filename:join([Root, "_build/docs/core", Path])),
    Data.

setup_test_() ->
    {setup, fun docs_fixture:setup/0, fun docs_fixture:cleanup/1,
     [fun links_become_source_pages/0, fun source_page_provenance/0,
      fun directory_links_list_their_children/0, fun broken_links_fail/0,
      fun images_are_staged_as_media/0, fun missing_images_fail/0,
      fun paths_outside_the_checkout_fail/0,
      fun source_links_name_their_files/0, fun diff_digest_is_not_output_bound/0]}.

links_become_source_pages() ->
    with_repository(fun(_, Context) ->
        {Text, State} = stage(Context, <<"README.md">>),
        ?assertEqual(<<"# Title\n\n[guide](docs/guide.md#a) "
                       "[demo](source/examples/demo.erl.html#L2) "
                       "[web](https://example.com/a.md) [top](#title)\n">>, Text),
        ?assertEqual([<<"examples/demo.erl">>], maps:keys(maps:get(sources, State)))
    end).

source_page_provenance() ->
    with_repository(fun(Root, #{head := Head} = Context) ->
        {_, State} = stage(Context, <<"README.md">>),
        Page = read(Root, "source/examples/demo.erl.html"),
        ?assertNotEqual(nomatch, binary:match(Page,
            <<"<span id=\"L2\">run() -&gt; a &lt; b.</span>">>)),
        ?assertNotEqual(nomatch, binary:match(Page,
            <<"https://github.com/libtmux/libtmux-erlang/blob/", Head/binary,
              "/examples/demo.erl\">Source at ">>)),
        ?assertMatch(#{<<"matches_head">> := true},
                     maps:get(<<"examples/demo.erl">>, maps:get(sources, State))),
        docs_fixture:write(Root, "examples/demo.erl", <<"-module(demo).\nchanged.\n">>),
        {_, Changed} = stage(Context, <<"README.md">>),
        ?assertMatch(#{<<"matches_head">> := false},
                     maps:get(<<"examples/demo.erl">>, maps:get(sources, Changed))),
        ?assertNotEqual(nomatch, binary:match(read(Root, "source/examples/demo.erl.html"),
            <<"Working tree preview.">>))
    end).

directory_links_list_their_children() ->
    with_repository(fun(Root, Context) ->
        docs_fixture:write(Root, "README.md", <<"[all](examples/)\n">>),
        {Text, State} = stage(Context, <<"README.md">>),
        ?assertEqual(<<"[all](source/examples/index.html)\n">>, Text),
        ?assertNotEqual(nomatch, binary:match(read(Root, "source/examples/index.html"),
            <<"<ul><li><a href=\"demo.erl.html\">demo.erl</a></li></ul>">>)),
        ?assertEqual([<<"examples">>, <<"examples/demo.erl">>],
                     lists:sort(maps:keys(maps:get(sources, State))))
    end).

broken_links_fail() ->
    with_repository(fun(Root, Context) ->
        docs_fixture:write(Root, "README.md", <<"[gone](docs/missing.md)\n">>),
        ?assertEqual(<<"Broken documentation link: README.md -> docs/missing.md">>,
                     failure(fun() -> stage(Context, <<"README.md">>) end))
    end).

images_are_staged_as_media() ->
    with_repository(fun(Root, Context) ->
        docs_fixture:write(Root, "README.md",
            <<"<img  src = 'docs/assets/logo.svg?v=1#x' alt=\"a\">\n"
              "<picture><source srcset=\"docs/assets/a.png 1x,docs/assets/b.png  2x\">"
              "<img src=\"https://example.com/i.png\" "
              "srcset=\"data:image/png;base64,AA 1x\"></picture>\n">>),
        {Text, State} = stage(Context, <<"README.md">>),
        ?assertEqual(<<"<img  src='media/docs/assets/logo.svg?v=1#x' alt=\"a\">\n"
              "<picture><source srcset=\"media/docs/assets/a.png 1x, media/docs/assets/b.png 2x\">"
              "<img src=\"https://example.com/i.png\" "
              "srcset=\"data:image/png;base64,AA 1x\"></picture>\n">>, Text),
        Media = maps:get(media, State),
        ?assertEqual([<<"media/docs/assets/a.png">>, <<"media/docs/assets/b.png">>,
                      <<"media/docs/assets/logo.svg">>], lists:sort(maps:keys(Media))),
        ?assertEqual(#{<<"source">> => <<"docs/assets/a.png">>,
                       <<"sha256">> => <<"ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785"
                                         "afee48bb">>},
                     maps:get(<<"media/docs/assets/a.png">>, Media))
    end).

missing_images_fail() ->
    with_repository(fun(Root, Context) ->
        docs_fixture:write(Root, "README.md", <<"<img src=\"docs/assets/absent.png\">\n">>),
        ?assertEqual(<<"Missing documentation image: README.md -> docs/assets/absent.png">>,
                     failure(fun() -> stage(Context, <<"README.md">>) end)),
        docs_fixture:write(Root, "README.md", <<"<img src=\"docs/assets\">\n">>),
        ?assertEqual(<<"Missing documentation image: README.md -> docs/assets">>,
                     failure(fun() -> stage(Context, <<"README.md">>) end))
    end).

paths_outside_the_checkout_fail() ->
    Outside = [{"outside.md", <<"# Outside\n">>}, {"outside.png", <<"png">>}],
    docs_fixture:with_tree(Outside ++ [{filename:join("repo", Path), Data}
                                       || {Path, Data} <- tree()], fun(Parent) ->
        Root = filename:join(Parent, "repo"),
        docs_fixture:init_repository(Root),
        Context = build_docs:context(Root, ?EXTRAS),
        docs_fixture:write(Root, "README.md", <<"[up](../outside.md)\n">>),
        ?assertEqual(<<"Broken documentation link: README.md -> ../outside.md">>,
                     failure(fun() -> stage(Context, <<"README.md">>) end)),
        docs_fixture:write(Root, "README.md", <<"<img src=\"../outside.png\">\n">>),
        ?assertEqual(<<"Missing documentation image: README.md -> ../outside.png">>,
                     failure(fun() -> stage(Context, <<"README.md">>) end))
    end).

source_links_name_their_files() ->
    with_repository(fun(Root, Context) ->
        docs_fixture:write(Root, "apps/app/src/m.erl", <<"-module(m).\n">>),
        State = build_docs:new_state(),
        {Url, _} = build_docs:source_link(Context, <<"m.erl">>, <<"1">>, State),
        ?assertEqual(<<"source/apps/app/src/m.erl.html#L1">>, iolist_to_binary(Url)),
        {Page, _} = build_docs:source_link(Context, <<"_build/docs/pages/README.md">>,
                                           <<"3">>, State),
        ?assertEqual(<<"source/README.md.html#L3">>, iolist_to_binary(Page)),
        docs_fixture:write(Root, "apps/other/src/m.erl", <<"-module(m).\n">>),
        ?assertEqual(<<"Ambiguous documentation source: m.erl">>,
                     failure(fun() ->
                         build_docs:source_link(Context, <<"m.erl">>, <<"1">>, State)
                     end))
    end).

diff_digest_is_not_output_bound() ->
    with_repository(fun(Root, _) ->
        Empty = binary:encode_hex(crypto:hash(sha256, <<>>), lowercase),
        ?assertEqual(Empty, build_docs:diff_sha256(Root)),
        docs_fixture:write(Root, "examples/demo.erl", <<"-module(demo).\nrun() -> b.\n">>),
        Small = build_docs:diff_sha256(Root),
        #{stdout := Diff} = script_util:run("git", ["diff", "--binary", "HEAD"], #{cwd => Root}),
        ?assertEqual(binary:encode_hex(crypto:hash(sha256, Diff), lowercase), Small),
        docs_fixture:write(Root, "examples/demo.erl", binary:copy(<<"line of source\n">>, 120000)),
        Large = build_docs:diff_sha256(Root),
        ?assertNotEqual(Small, Large),
        ?assertEqual(Large, build_docs:diff_sha256(Root)),
        ?assertNot(filelib:is_file(filename:join(Root, "_build/docs/working-tree.diff")))
    end).

manifest(Digest) ->
    #{<<"version">> => <<"1.0.0">>, <<"otp">> => <<"29">>, <<"url">> => <<"https://x">>,
      <<"sha256">> => Digest}.

tool_validation_test() ->
    Digest = binary:encode_hex(crypto:hash(sha256, <<"tool">>), lowercase),
    docs_fixture:with_tree([{"ex_doc", <<"tool">>}, {"other", <<"tampered">>}], fun(Root) ->
        Tool = filename:join(Root, "ex_doc"),
        ?assert(build_docs:tool_valid(Tool, manifest(Digest))),
        ?assertNot(build_docs:tool_valid(filename:join(Root, "other"), manifest(Digest))),
        ?assertNot(build_docs:tool_valid(filename:join(Root, "absent"), manifest(Digest))),
        ok = file:make_symlink("ex_doc", filename:join(Root, "link")),
        ?assertNot(build_docs:tool_valid(filename:join(Root, "link"), manifest(Digest)))
    end).

download_verification_test() ->
    Digest = binary:encode_hex(crypto:hash(sha256, <<"tool">>), lowercase),
    ?assertEqual(ok, build_docs:verify_download(<<"tool">>, manifest(Digest))),
    ?assertError({build_docs, <<"ExDoc download does not match the pinned digest">>},
                 build_docs:verify_download(<<"tampered">>, manifest(Digest))),
    Big = binary:copy(<<"x">>, 8 * 1024 * 1024 + 1),
    BigDigest = binary:encode_hex(crypto:hash(sha256, Big), lowercase),
    ?assertError({build_docs, _}, build_docs:verify_download(Big, manifest(BigDigest))).

proxy_test() ->
    ?assertEqual([], build_docs:proxy("")),
    ?assertMatch([{https_proxy, {{"proxy.example", 3128}, _}}],
                 build_docs:proxy("http://proxy.example:3128")),
    ?assertMatch([{https_proxy, {{"proxy.example", 80}, _}}],
                 build_docs:proxy("http://proxy.example")),
    ?assertMatch([{https_proxy, {{"proxy.example", 8080}, _}}],
                 build_docs:proxy("proxy.example:8080")).
