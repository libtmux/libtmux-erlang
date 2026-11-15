-module(check_docs_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

-define(GUIDE, <<"# Guide\n\n## Usage & Notes\n\nText.\n\n```console\n$ echo ok\n```\n">>).
-define(NATIVE, <<"-module(m).\n-moduledoc \"\"\"\n```erlang\n1> ok.\nok\n```\n\"\"\".\n">>).

tree() ->
    [{"README.md", <<"# Title\n\nSee [guide](docs/guide.md#usage--notes).\n">>},
     {"docs/guide.md", ?GUIDE},
     {"apps/app/src/m.erl", ?NATIVE},
     {"examples/demo.erl", <<"-module(demo).\n-export([run/0]).\nrun() -> ok.\n">>},
     {"examples/input.json", <<"{\"a\": 1}\n">>}].

with(Replacements, Fun) ->
    Files = lists:foldl(fun({Path, _} = Entry, Acc) -> lists:keystore(Path, 1, Acc, Entry) end,
                        tree(), Replacements),
    docs_fixture:with_tree(Files, Fun).

failure(Replacements) ->
    with(Replacements, fun(Root) ->
        try check_docs:check(Root, #{}) of
            Receipt -> {passed, Receipt}
        catch error:{docs_check, Where, Reason} -> {Where, Reason}
        end
    end).

field(Name, {object, Pairs}) -> element(2, lists:keyfind(Name, 1, Pairs)).

fenced(Language, Body) -> iolist_to_binary(["```", Language, "\n", Body, "```\n"]).

setup_test_() ->
    {setup, fun docs_fixture:setup/0, fun docs_fixture:cleanup/1,
     [fun html_checks/0, fun html_source_links/0]}.

valid_corpus_passes_test() ->
    with([], fun(Root) ->
        Receipt = check_docs:check(Root, #{}),
        ?assertEqual(<<"PASS">>, field(<<"result">>, Receipt)),
        ?assertEqual(2, field(<<"files">>, Receipt)),
        ?assertEqual(1, field(<<"console_units">>, Receipt)),
        ?assertEqual(1, field(<<"native_code_lines">>, Receipt)),
        ?assertEqual(<<"UNVERIFIED in this static check">>, field(<<"runtime_output">>, Receipt)),
        {ok, Written} = file:read_file(filename:join(Root, "_build/checks/docs-corpus.json")),
        ?assertEqual(<<(docs_util:json_text(Receipt))/binary, "\n">>, Written)
    end).

broken_relative_link_fails_test() ->
    ?assertEqual({<<"README.md">>, {missing_link_target, <<"docs/missing.md">>}},
                 failure([{"README.md", <<"[gone](docs/missing.md)\n">>}])).

link_leaving_the_checkout_fails_test() ->
    docs_fixture:with_tree([{"outside.md", <<"# Outside\n">>} | tree()], fun(Parent) ->
        Root = filename:join(Parent, "repo"),
        ok = file:make_dir(Root),
        lists:foreach(fun({Path, Data}) -> docs_fixture:write(Root, Path, Data) end,
                      [{"README.md", <<"[up](../outside.md)\n">>}]),
        ?assertError({docs_check, <<"README.md">>, {missing_link_target, <<"../outside.md">>}},
                     check_docs:check(Root, #{}))
    end).

missing_fragment_fails_test() ->
    ?assertEqual({<<"README.md">>, {missing_fragment, <<"docs/guide.md#nope">>}},
                 failure([{"README.md", <<"[guide](docs/guide.md#nope)\n">>}])).

external_and_image_links_are_not_checked_test() ->
    ?assertMatch({passed, _}, failure([{"README.md",
        <<"[a](https://example.com/x) [b](#top) [c](mailto:a@b) ![d](missing.png)\n">>}])).

example_excerpt_must_match_its_source_test() ->
    Block = fenced("erlang", <<"-module(demo).\n-export([run/0]).\nrun() -> ok.\n">>),
    ?assertMatch({passed, _}, failure([{"README.md",
        iolist_to_binary(["<!-- example: examples/demo.erl -->\n\n", Block])}])),
    Drifted = fenced("erlang", <<"-module(demo).\nrun() -> changed.\n">>),
    ?assertEqual({<<"README.md">>, {example_drift, <<"examples/demo.erl">>}},
                 failure([{"README.md",
                           iolist_to_binary(["<!-- example: examples/demo.erl -->\n", Drifted])}])),
    ?assertEqual({<<"README.md">>, {example_drift, <<"examples/absent.erl">>}},
                 failure([{"README.md",
                           iolist_to_binary(["<!-- example: examples/absent.erl -->\n", Block])}])).

unclassified_blocks_fail_test() ->
    ?assertEqual({<<"README.md">>, unclassified_erlang_block},
                 failure([{"README.md", fenced("erlang", <<"ok.\n">>)}])),
    ?assertEqual({<<"README.md">>, {unclassified_code_block, <<"python">>}},
                 failure([{"README.md", fenced("python", <<"x = 1\n">>)}])),
    ?assertEqual({<<"README.md">>, {unclassified_code_block, <<>>}},
                 failure([{"README.md", fenced("", <<"x\n">>)}])),
    ?assertEqual({<<"README.md">>, unclassified_json_block},
                 failure([{"README.md", fenced("json", <<"{}\n">>)}])).

console_block_holds_one_command_test() ->
    ?assertMatch({passed, _}, failure([{"README.md", fenced("console", <<"$ ls \\\n    -l\n">>)}])),
    ?assertEqual({<<"README.md">>, {console_unit, <<"$ ls\n$ pwd\n">>}},
                 failure([{"README.md", fenced("console", <<"$ ls\n$ pwd\n">>)}])),
    ?assertEqual({<<"README.md">>, {console_unit, <<"ls\n">>}},
                 failure([{"README.md", fenced("console", <<"ls\n">>)}])).

erlang_terms_are_consulted_test() ->
    Marker = "<!-- erlang-term -->\n",
    ?assertMatch({passed, _}, failure([{"README.md",
        iolist_to_binary([Marker, fenced("erlang", <<"{key, \"value\"}.\n">>)])}])),
    ?assertMatch({<<"doc-terms.config">>, {invalid_erlang_terms, _}},
                 failure([{"README.md",
                           iolist_to_binary([Marker, fenced("erlang", <<"{key, \n">>)])}])).

json_input_must_match_its_file_test() ->
    Marker = "<!-- example-input: examples/input.json -->\n",
    Matching = iolist_to_binary([Marker, fenced("json", <<"{\"a\": 1}\n">>)]),
    ?assertMatch({passed, _}, failure([{"README.md", Matching}])),
    ?assertEqual({<<"README.md">>, {input_drift, <<"examples/input.json">>}},
                 failure([{"README.md",
                           iolist_to_binary([Marker, fenced("json", <<"{\"a\": 2}\n">>)])}])).

native_example_width_counts_columns_test() ->
    Native = fun(Line) ->
        {"apps/app/src/m.erl", iolist_to_binary(["-moduledoc \"\"\"\n```erlang\n", Line,
                                                  "\n```\n\"\"\".\n"])}
    end,
    Edge = list_to_binary(["1> ", lists:duplicate(77, $x)]),
    ?assertMatch({passed, _}, failure([Native(Edge)])),
    Wider = <<Edge/binary, "x">>,
    ?assertEqual({<<"apps/app/src/m.erl">>, {native_example_wider_than_80, Wider}},
                 failure([Native(Wider)])),
    Wide = unicode:characters_to_binary(["1> ", lists:duplicate(39, 16#65E5)]),
    ?assertEqual(42, string:length(Wide)),
    ?assertEqual({<<"apps/app/src/m.erl">>, {native_example_wider_than_80, Wide}},
                 failure([Native(Wide)])),
    ?assertMatch({passed, _}, failure([Native(unicode:characters_to_binary(
        ["1> ", lists:duplicate(38, 16#65E5)]))])),
    Prose = <<"also_not_a_prompt ", (binary:copy(<<"x">>, 90))/binary>>,
    ?assertMatch({passed, _}, failure([Native(Prose)])).

columns_test() ->
    ?assertEqual(0, check_docs:columns(<<>>)),
    ?assertEqual(3, check_docs:columns(<<"abc">>)),
    ?assertEqual(4, check_docs:columns(unicode:characters_to_binary([16#65E5, 16#672C]))),
    ?assertEqual(2, check_docs:columns(unicode:characters_to_binary([16#FF21]))),
    ?assertEqual(2, check_docs:columns(unicode:characters_to_binary([16#1F600]))),
    ?assertEqual(1, check_docs:columns(unicode:characters_to_binary([16#FF61]))),
    ?assertEqual(1, check_docs:columns(unicode:characters_to_binary([16#E9]))),
    ?assertEqual(1, check_docs:columns(unicode:characters_to_binary([16#10FF]))),
    ?assertEqual(2, check_docs:columns(unicode:characters_to_binary([16#1100]))),
    ?assertEqual(2, check_docs:columns(unicode:characters_to_binary([16#115F]))),
    ?assertEqual(1, check_docs:columns(unicode:characters_to_binary([16#1160]))),
    ?assertEqual(2, check_docs:columns(unicode:characters_to_binary([16#3FFFD]))),
    ?assertEqual(1, check_docs:columns(unicode:characters_to_binary([16#3FFFE]))).

runtime_receipt_must_match_displayed_output_test() ->
    Block = iolist_to_binary(["<!-- example-output: demo -->\n",
                              fenced("json", <<"{\"n\": 1}\n">>)]),
    Receipt = fun(Result, Cleanup, Output) ->
        iolist_to_binary(json:encode(#{result => Result, examples => [#{module => demo,
            output => Output, sessions_removed => true, owned_cleanup => Cleanup}]}))
    end,
    Run = fun(Json) ->
        with([{"README.md", Block}, {"_build/checks/examples.json", Json}], fun(Root) ->
            try check_docs:check(Root, #{examples_receipt => "_build/checks/examples.json"}) of
                Result -> {passed, Result}
            catch error:{docs_check, Where, Reason} -> {Where, Reason}
            end
        end)
    end,
    {passed, Passed} = Run(Receipt('PASS', complete, #{n => 1})),
    ?assertEqual(<<"PASS">>, field(<<"runtime_output">>, Passed)),
    ?assertEqual([<<"demo">>], field(<<"displayed_outputs">>, Passed)),
    ?assertEqual({<<"README.md">>, {output_drift, <<"demo">>}},
                 Run(Receipt('PASS', complete, #{n => 2}))),
    ?assertEqual({<<"examples receipt">>, {result_not_pass, <<"RUNNING">>}},
                 Run(Receipt('RUNNING', complete, #{n => 1}))),
    ?assertEqual({<<"examples receipt">>, {incomplete_cleanup, <<"demo">>}},
                 Run(Receipt('PASS', partial, #{n => 1}))).

runtime_receipt_is_named_apart_test() ->
    with([{"_build/checks/examples.json", <<"{\"result\":\"PASS\",\"examples\":[]}">>}],
        fun(Root) ->
            _ = check_docs:check(Root, #{examples_receipt => "_build/checks/examples.json"}),
            ?assert(filelib:is_regular(
                filename:join(Root, "_build/checks/docs-corpus-runtime.json")))
        end).

scan_html_test() ->
    Html = <<"<!doctype html><!-- <a href=\"ignored\"> --><HTML><head>"
             "<link rel=stylesheet href=\"dist/app.css\"><script src=\"dist/app.js\">"
             "document.write('<a href=\"x\">')</script></head>"
             "<body id=top><a href=\"b.html#h&amp;1\" id=\"a1\">b</a><a name=n>no href</a>"
             "<img src='i.png' srcset=\"i.png 1x, j.png 2x\"><br/>"
             "<source srcset=\"data:image/png;base64,AAA,BBB\">"
             "<img srcset=\"a.png\"><title><a href=\"title\"></title><a href=\"\">"
             "<a id=\"a2\" href=last.html></body>">>,
    ?assertEqual(#{links => [<<"b.html#h&1">>, <<"last.html">>],
                   resources => [<<"dist/app.css">>, <<"dist/app.js">>, <<"i.png">>, <<"i.png">>,
                                 <<"j.png">>, <<"a.png">>],
                   anchors => #{<<"top">> => true, <<"a1">> => true, <<"a2">> => true}},
                 check_docs:scan_html(Html)).

page(Body) -> <<"<!doctype html><html><body>", Body/binary, "</body></html>">>.

html_failure(Pages, Directory) ->
    docs_fixture:with_tree([{filename:join(Directory, Name), page(Body)} || {Name, Body} <- Pages],
        fun(Root) ->
            try check_docs:check_html(filename:join(Root, Directory), Root) of
                Result -> {passed, Result}
            catch error:{docs_check, Where, Reason} -> {Where, Reason}
            end
        end).

html_checks() ->
    Good = [{"a.html", <<"<h1 id=\"top\">x</h1><a href=\"b.html#sec\">b</a><a href=\"#top\">t</a>"
                         "<a href=\"https://example.com/\">e</a><img src=\"i.png\">">>},
            {"b.html", <<"<h2 id=\"sec\">s</h2><a href=\"a.html\">a</a>">>},
            {"i.png", <<"png">>}],
    ?assertEqual({passed, {object, [{<<"pages">>, 2}, {<<"links">>, 4}, {<<"resources">>, 1}]}},
                 html_failure(Good, "out")),
    ?assertEqual({<<"a.html">>, {missing_anchor, <<"b.html#nope">>}},
                 html_failure([{"a.html", <<"<a href=\"b.html#nope\">b</a>">>},
                               {"b.html", <<"<h2 id=\"sec\"></h2>">>}], "out")),
    ?assertEqual({<<"a.html">>, {missing_anchor, <<"#nope">>}},
                 html_failure([{"a.html", <<"<a href=\"#nope\">b</a>">>}], "out")),
    ?assertEqual({<<"a.html">>, {missing_rendered_target, <<"missing.png">>}},
                 html_failure([{"a.html", <<"<img src=\"missing.png\">">>}], "out")),
    ?assertEqual({<<"a.html">>, {missing_rendered_target, <<"gone.html">>}},
                 html_failure([{"a.html", <<"<a href=\"gone.html\">x</a>">>}], "out")),
    ?assertEqual({<<"a.html">>, {missing_rendered_target, <<"../outside.css">>}},
                 html_failure([{"a.html", <<"<link href=\"../outside.css\">">>}], "out")).

html_source_links() ->
    Source = fun(Revision, Path) ->
        iolist_to_binary(["<a href=\"https://github.com/libtmux/libtmux-erlang/blob/", Revision,
                          "/", Path, "\">s</a>"])
    end,
    docs_fixture:with_tree([{"src/my file.erl", <<"-module(m).\n">>}], fun(Root) ->
        docs_fixture:init_repository(Root),
        Commit = docs_fixture:git(Root, ["rev-parse", "HEAD"]),
        Check = fun(Body) ->
            ok = docs_util:write_file(filename:join(Root, "out/a.html"), page(Body)),
            try check_docs:check_html(filename:join(Root, "out"), Root) of
                Result -> {passed, Result}
            catch error:{docs_check, Where, Reason} -> {Where, Reason}
            end
        end,
        ?assertMatch({passed, _}, Check(Source("HEAD", "src/my%20file.erl"))),
        ?assertMatch({passed, _}, Check(Source(string:trim(Commit, trailing), "src"))),
        ?assertMatch({passed, _}, Check(<<(Source("main", "src/my%20file.erl"))/binary,
                                          (Source("HEAD", "src"))/binary>>)),
        ?assertMatch({<<"a.html">>, {missing_source_at_revision, _}},
                     Check(Source("HEAD", "src/absent.erl"))),
        ?assertMatch({<<"a.html">>, {missing_source_at_revision, _}},
                     Check(Source("0123456789abcdef", "src/my%20file.erl")))
    end).
