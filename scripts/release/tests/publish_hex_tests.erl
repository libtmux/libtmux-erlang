-module(publish_hex_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

an_unpublished_version_submits_package_and_docs_without_waiting_test() ->
    ?assertEqual([["rebar3", "as", "release", "hex", "publish",
                   "--yes", "--doc-dir", "/repo/_build/docs/core"]],
                 publish_hex:plan("/repo", false)).

a_published_version_submits_only_docs_without_waiting_test() ->
    ?assertEqual([["rebar3", "as", "release", "hex", "publish", "docs",
                   "--app", "libtmux_erlang", "--yes", "--doc-dir", "/repo/_build/docs/core"]],
                 publish_hex:plan("/repo", true)).

an_empty_key_is_unset_and_a_real_key_is_kept_test() ->
    Unset = #{<<"HEX_API_KEY">> => false},
    ?assertEqual(Unset, publish_hex:environment(false)),
    ?assertEqual(Unset, publish_hex:environment("")),
    ?assertEqual(#{}, publish_hex:environment("secret")).
