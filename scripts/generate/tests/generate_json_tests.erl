-module(generate_json_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").
-dialyzer({nowarn_function, rejects_values_with_no_stable_text_test/0}).

document() ->
    [{<<"text">>, <<"q\"b\\s/\n\r\t\b\f\x01\x1f\x7f \x{e9}\x{2014}\x{1f600}"/utf8>>},
     {<<"n">>, [-5, 0, 12]},
     {<<"flags">>, [true, false, null]},
     {<<"empty">>, []},
     {<<"none">>, #{}},
     {<<"deep">>, [{<<"b">>, [[{<<"z">>, 1}, {<<"a">>, [[]]}], []]}, {<<"a">>, <<"x">>}]}].

%% Expected text comes from Python's json.dumps(indent=2).
python_text() ->
    """
    {
      "text": "q\"b\\s/\n\r\t\b\f\u0001\u001f\u007f \u00e9\u2014\ud83d\ude00",
      "n": [
        -5,
        0,
        12
      ],
      "flags": [
        true,
        false,
        null
      ],
      "empty": [],
      "none": {},
      "deep": {
        "b": [
          {
            "z": 1,
            "a": [
              []
            ]
          },
          []
        ],
        "a": "x"
      }
    }
    """.

encode_matches_python_test() ->
    ?assertEqual(python_text(), unicode:characters_to_list(generate_json:encode(document()))).

decode_keeps_key_order_test() ->
    Text = <<"{\"b\": 1, \"a\": {\"z\": [], \"y\": {}}, \"c\": [{\"x\": null}]}">>,
    ?assertEqual([{<<"b">>, 1}, {<<"a">>, [{<<"z">>, []}, {<<"y">>, #{}}]},
                  {<<"c">>, [[{<<"x">>, null}]]}],
                 generate_json:decode(Text)).

decode_round_trips_the_document_test() ->
    Text = iolist_to_binary(generate_json:encode(document())),
    ?assertEqual(document(), generate_json:decode(Text)).

committed_json_round_trips_test_() ->
    [{File, fun() ->
         {ok, Bytes} = file:read_file(File),
         ?assertEqual(Bytes, iolist_to_binary([generate_json:encode(generate_json:decode(Bytes)),
                                               "\n"]))
     end} || File <- ["schema/commands.json", "schema/options.json",
                      "schema/tmux-sources.json"]].

rejects_values_with_no_stable_text_test() ->
    ?assertError(function_clause, generate_json:encode(1.5)),
    ?assertError(function_clause, generate_json:encode(undefined)),
    ?assertError(function_clause, generate_json:encode(#{<<"a">> => 1, <<"b">> => 2})),
    ?assertError({invalid_utf8, _}, generate_json:encode(<<255>>)).

rejects_invalid_text_test() ->
    ?assertError({trailing_data, _}, generate_json:decode(<<"1 2">>)),
    ?assertError(_, generate_json:decode(<<"{\"a\": ">>)).
