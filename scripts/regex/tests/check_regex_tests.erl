-module(check_regex_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

payload_pairs_each_rendering_with_a_hex_subject_test() ->
    Patterns = [#{<<"javascript">> => <<"^a$">>,
                  <<"cases">> => [#{<<"subject">> => <<"a">>}, #{<<"subject">> => <<0, 255>>}]}],
    ?assertEqual(<<"^a$\t61\n^a$\t00ff\n">>, check_regex:payload(<<"javascript">>, Patterns)).

differences_name_the_mismatching_cases_test() ->
    ?assertEqual([], check_regex:differences([<<"true">>, <<"false">>], [<<"true">>, <<"false">>])),
    ?assertEqual([{1, <<"true">>, <<"false">>}],
                 check_regex:differences([<<"true">>, <<"true">>], [<<"true">>, <<"false">>])),
    ?assertEqual([{length, <<"1">>, <<"2">>}],
                 check_regex:differences([<<"true">>], [<<"true">>, <<"false">>])).

crate_version_comes_from_the_lock_file_test() ->
    ?assertEqual(<<"1.2.3">>, check_regex:crate_version(
        <<"[[package]]\nname = \"aho\"\nversion = \"0.1\"\n\n"
          "[[package]]\nname = \"regex\"\nversion = \"1.2.3\"\n">>)),
    ?assertError(regex_crate_missing, check_regex:crate_version(<<"[[package]]\n">>)),
    {ok, Lock} = file:read_file("tools/regex-conformance/Cargo.lock"),
    ?assertMatch(<<_, _/binary>>, check_regex:crate_version(Lock)).
