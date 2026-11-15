-module(generate_fixture_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

%% Reference values from CPython's random.Random(2912).
twister_matches_python_test() ->
    Words = draw(32, 700, generate_fixture:rng_new(2912), []),
    ?assertEqual([3615483751, 3344378118, 193271351, 725868337, 1655058163],
                 lists:sublist(Words, 5)),
    ?assertEqual(2086211319, lists:last(Words)).

bounded_draws_match_python_test() ->
    Rng0 = generate_fixture:rng_new(2912),
    {Counts, Rng1} = lists:mapfoldl(fun(_, R) -> generate_fixture:rng_below(3, R) end,
                                    Rng0, lists:seq(1, 5)),
    ?assertEqual([0, 0, 1, 1, 2], Counts),
    {Picks, _} = lists:mapfoldl(fun(_, R) -> generate_fixture:rng_below(4, R) end,
                                Rng1, lists:seq(1, 5)),
    ?assertEqual([0, 3, 2, 0, 2], Picks).

committed_fixture_is_reproduced_test() ->
    {ok, Committed} = file:read_file("test/fixtures/regex-v1.json"),
    ?assertEqual(Committed, generate_fixture:render(generate_fixture:fixture())).

changed_fixture_is_detected_test() ->
    {ok, Committed} = file:read_file("test/fixtures/regex-v1.json"),
    {obj, Pairs} = generate_fixture:fixture(),
    Changed = {obj, lists:keyreplace(dialect, 1, Pairs, {dialect, <<"other">>})},
    ?assertNotEqual(Committed, generate_fixture:render(Changed)).

json_layout_and_escapes_test() ->
    Value = {obj, [{a, [1, true]}, {b, <<"q\"\\\n\r\t\b\f\0\x7f", 16#c3, 16#a9>>}]},
    ?assertEqual(<<"{\n  \"a\": [\n    1,\n    true\n  ],\n"
                   "  \"b\": \"q\\\"\\\\\\n\\r\\t\\b\\f\\u0000\x7f", 16#c3, 16#a9, "\"\n}\n">>,
                 generate_fixture:render(Value)).

oracle_follows_the_grammar_test() ->
    Anchored = {seq, [start, {rep, {lit, $a}, 0, 2}, 'end']},
    ?assert(generate_fixture:oracle(Anchored, "")),
    ?assert(generate_fixture:oracle(Anchored, "aa")),
    ?assertNot(generate_fixture:oracle(Anchored, "aaa")),
    ?assertNot(generate_fixture:oracle({seq, [start, dot, 'end']}, "\n")),
    ?assert(generate_fixture:oracle({seq, [start, dot, 'end']}, "\r")),
    ?assert(generate_fixture:oracle({alt, [{lit, $a}, {set, [$b, $c]}]}, "zc")),
    ?assertNot(generate_fixture:oracle({rep, {lit, $a}, 2, 3}, "a")).

spelling_uses_hex_escapes_test() ->
    ?assertEqual("(\\x61){0,3}", generate_fixture:spelling({rep, {lit, $a}, 0, 3})),
    ?assertEqual("((.[\\x61\\x62])|(^$))",
                 generate_fixture:spelling({alt, [{seq, [dot, {set, [$a, $b]}]},
                                                  {seq, [start, 'end']}]})).

draw(_, 0, _, Acc) -> lists:reverse(Acc);
draw(K, Count, Rng0, Acc) ->
    {Word, Rng1} = generate_fixture:rng_bits(K, Rng0),
    draw(K, Count - 1, Rng1, [Word | Acc]).
