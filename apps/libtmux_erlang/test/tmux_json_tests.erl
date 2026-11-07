-module(tmux_json_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

bounded_decode_test() ->
    ?assertEqual({ok, #{<<"x">> => [1, true, null, 1.5]}},
        tmux_json:decode(<<"{\"x\": [1,true,null,1.5]} \n\t">>)),
    ?assertMatch({error, #{code := duplicate_key, path := [<<"x">>, 1, <<"a">>]}},
        tmux_json:decode(<<"{\"x\":[0,{\"a\":1,\"\\u0061\":2}]}">>)),
    ?assertMatch({error, #{code := trailing_input}}, tmux_json:decode(<<"{}true">>)),
    ?assertMatch({error, #{code := invalid_json}}, tmux_json:decode(<<"{\"x\":">>)),
    ?assertMatch({error, #{code := invalid_json}}, tmux_json:decode(<<"\"",255,"\"">>)),
    AtLimit = iolist_to_binary([lists:duplicate(32, $[), <<"0">>, lists:duplicate(32, $])]),
    ?assertMatch({ok, _}, tmux_json:decode(AtLimit)),
    ?assertMatch({error, #{code := depth_limit}}, tmux_json:decode(<<"[",AtLimit/binary,"]">>)),
    ?assertMatch({error, #{code := document_limit}}, tmux_json:decode(binary:copy(<<" ">>, 262145))),
    ?assertMatch({error, #{code := number_out_of_range}}, tmux_json:decode(<<"9007199254740992">>)),
    ?assertMatch({error, #{code := number_out_of_range}}, tmux_json:decode(<<"1e9999">>)).

numeric_rounding_must_not_change_filter_meaning_test() ->
    ?assertMatch({error, #{code := nonintegral_number, path := [<<"width">>]}},
        tmux_json:decode(<<"{\"width\":1.0000000000000000001}">>)),
    ?assertMatch({error, #{code := nonintegral_number}}, tmux_json:decode(<<"1e-999">>)),
    ?assertEqual({ok, 9007199254740991}, tmux_json:decode(<<"9007199254740991.0">>)).
