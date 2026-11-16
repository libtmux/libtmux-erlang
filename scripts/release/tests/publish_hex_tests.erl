-module(publish_hex_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

an_unpublished_version_publishes_package_then_docs_test() ->
    [Package, Docs] = publish_hex:plan("/repo", false),
    ?assertEqual(["rebar3", "as", "release", "hex", "publish", "package"],
                 lists:sublist(Package, 6)),
    ?assertEqual(["rebar3", "as", "release", "hex", "publish", "docs"],
                 lists:sublist(Docs, 6)),
    ?assertEqual(["--doc-dir", "/repo/_build/docs/core"], lists:nthtail(length(Docs) - 2, Docs)).

a_published_version_publishes_only_the_docs_test() ->
    ?assertMatch([[_, _, _, _, _, "docs" | _]], publish_hex:plan("/repo", true)).

an_empty_key_is_unset_and_a_real_key_is_kept_test() ->
    Unset = #{<<"HEX_API_KEY">> => false},
    ?assertEqual(Unset, publish_hex:environment(false)),
    ?assertEqual(Unset, publish_hex:environment("")),
    ?assertEqual(#{}, publish_hex:environment("secret")).
