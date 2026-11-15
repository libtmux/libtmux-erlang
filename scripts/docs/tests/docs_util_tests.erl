-module(docs_util_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

urlsplit_test() ->
    ?assertEqual(#{scheme => <<"https">>, netloc => <<"github.com">>, path => <<"/a/b">>,
                   query => <<"q=1">>, fragment => <<"L3">>},
                 docs_util:urlsplit(<<"HTTPS://github.com/a/b?q=1#L3">>)),
    ?assertEqual(#{scheme => <<>>, netloc => <<>>, path => <<"../x.html">>, query => <<>>,
                   fragment => <<"top">>},
                 docs_util:urlsplit(<<" ../x.ht\tml#top">>)),
    ?assertMatch(#{scheme := <<"data">>, path := <<"image/png;base64,AAA">>},
                 docs_util:urlsplit(<<"data:image/png;base64,AAA">>)),
    ?assertMatch(#{netloc := <<"cdn.example">>, path := <<>>},
                 docs_util:urlsplit(<<"//cdn.example">>)).

quote_and_unquote_test() ->
    ?assertEqual(<<"media/a%20b/%C3%A9.png">>,
                 docs_util:quote(<<"media/a b/\xC3\xA9.png">>, <<"/">>)),
    ?assertEqual(<<"a%2Fb">>, docs_util:quote(<<"a/b">>, <<>>)),
    ?assertEqual(<<"a b/\xC3\xA9%zz">>, docs_util:unquote(<<"a%20b/%C3%A9%zz">>)),
    ?assertEqual(<<"\xEF\xBF\xBD">>, docs_util:unquote(<<"%FF">>)).

escape_and_unescape_test() ->
    ?assertEqual(<<"&lt;a href=&quot;x&quot;&gt;&amp;&#x27;">>,
                 docs_util:escape(<<"<a href=\"x\">&'">>)),
    ?assertEqual(<<"<a & b> \" ' \xC3\xA9 &unknown; \xEF\xBF\xBD">>,
                 docs_util:unescape(<<"&lt;a &amp; b&gt; &quot; &#39; &#xE9; &unknown; &#0;">>)),
    ?assertEqual(<<"plain">>, docs_util:unescape(<<"plain">>)).

splitlines_test() ->
    ?assertEqual([], docs_util:splitlines(<<>>)),
    ?assertEqual([<<"a">>, <<"b">>], docs_util:splitlines(<<"a\r\nb\n">>)),
    ?assertEqual([<<"a">>, <<>>, <<"b">>], docs_util:splitlines(<<"a\n\nb">>)),
    ?assertEqual([<<"a">>, <<"b">>], docs_util:splitlines(<<"a\nb">>)),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], docs_util:splitlines(<<"a\fb\xE2\x80\xA8c">>)).

replace_threads_state_test() ->
    ?assertEqual({<<"[1]-[2]">>, 2},
                 docs_util:replace("[a-z]", <<"x-y">>,
                                   fun([_], N) -> {[$[, integer_to_binary(N + 1), $]], N + 1} end,
                                   0)).

resolve_follows_links_and_dots_test() ->
    docs_fixture:with_tree([{"real/file", <<"x">>}], fun(Root) ->
        ok = file:make_symlink("real", filename:join(Root, "link")),
        Real = docs_util:resolve(filename:join(Root, "real")),
        ?assertEqual(filename:join(Real, "file"),
                     docs_util:resolve(filename:join([Root, "link", "..", "real", ".", "file"]))),
        ?assertEqual(Real, docs_util:resolve(filename:join(Root, "link"))),
        ?assertEqual(filename:join(Real, "absent"),
                     docs_util:resolve(filename:join([Root, "link", "absent"]))),
        ?assert(docs_util:is_within(Real, docs_util:resolve(filename:join(Root, "link")))),
        ?assertNot(docs_util:is_within(Real, filename:dirname(Real))),
        ?assertEqual(<<"file">>, docs_util:relative_to(filename:join(Real, "file"), Real)),
        ?assertEqual(<<".">>, docs_util:relative_to(Real, Real))
    end).

relative_path_test() ->
    ?assertEqual(<<"../../a/b.html">>, docs_util:relative_path(<<"/o/a/b.html">>, <<"/o/c/d">>)),
    ?assertEqual(<<"x.html">>, docs_util:relative_path(<<"/o/s/x.html">>, <<"/o/s">>)).

json_text_matches_python_layout_test() ->
    Value = {object, [{<<"b">>, [1, 2.5, true, null]}, {<<"a">>, {object, []}},
                      {<<"s">>, <<"q\"\\\n\xC3\xA9\xF0\x9F\x98\x80\x7F">>}, {<<"l">>, []}]},
    ?assertEqual(<<"{\n  \"b\": [\n    1,\n    2.5,\n    true,\n    null\n  ],\n"
                   "  \"a\": {},\n"
                   "  \"s\": \"q\\\"\\\\\\n\\u00e9\\ud83d\\ude00\\u007f\",\n"
                   "  \"l\": []\n}">>, docs_util:json_text(Value)).

ordered_json_keeps_file_order_test() ->
    docs_fixture:with_tree([{"m.json", <<"{\"version\": \"1\", \"a\": {\"z\": 1, \"b\": 2}}\n">>}],
        fun(Root) ->
            ?assertEqual({object, [{<<"version">>, <<"1">>},
                                   {<<"a">>, {object, [{<<"z">>, 1}, {<<"b">>, 2}]}}]},
                         docs_util:read_ordered_json(filename:join(Root, "m.json")))
        end).
