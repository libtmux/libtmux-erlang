-module(check_helper_native_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

%% The seed corpus is pinned by its size and the digest of its sorted contents.
seed_corpus_matches_the_reference_test() ->
    Seeds = check_helper_native:seeds(),
    ?assertEqual(176, length(Seeds)),
    ?assertEqual(<<"98c3cc98ac2960b56669dd1e3b4bdf17e8f48505188ca4a39207357bd68751bd">>,
                 script_util:sha256_hex(iolist_to_binary(lists:sort(Seeds)))).

frames_carry_a_big_endian_length_test() ->
    ?assertEqual(<<0, 3, "abc">>, check_helper_native:frame(<<"abc">>)).

sanitizer_flags_fail_on_any_finding_test() ->
    Flags = check_helper_native:flags(),
    ?assert(lists:member("-fsanitize=address,undefined", Flags)),
    ?assert(lists:member("-fno-sanitize-recover=all", Flags)),
    ?assert(lists:member("-Werror", Flags)).
