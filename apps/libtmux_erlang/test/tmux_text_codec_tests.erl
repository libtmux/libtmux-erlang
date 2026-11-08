-module(tmux_text_codec_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

quoted_field_print_layers_test() ->
    Expected = <<"x\r\\r $HOME", 255>>,
    Cases = [
        {<<"tmux 3.3">>, <<"x\r\\\\r\\ \\$HOME", 255>>},
        {<<"tmux 3.4">>, <<"x\\r\\\\r\\ \\\\$HOME\\377">>},
        {<<"tmux 3.5a">>, <<"x\\r\\\\r\\ \\$HOME\\377">>},
        {<<"tmux 3.8">>, <<"x\r\\\\r\\ \\$HOME", 255>>}
    ],
    lists:foreach(fun({Release, Bytes}) ->
        {ok, Version} = tmux_version:parse(Release),
        ?assertEqual({ok, Expected}, tmux_text_codec:format(Bytes, Version))
    end, Cases).

quoted_field_specials_test() ->
    {ok, Version} = tmux_version:parse(<<"tmux 3.8">>),
    ?assertEqual({ok, <<"|&;<>(){}$`\\\"'*?[# =%\n\t">>},
        tmux_text_codec:format(
            <<"\\|\\&\\;\\<\\>\\(\\)\\{\\}\\$\\`\\\\\\\"\\'\\*\\?\\[\\#\\ \\=\\%\\\n\\\t">>,
            Version)),
    ?assertEqual({ok, <<"'x'">>}, tmux_text_codec:format(<<"\\'x\\'">>, Version)),
    ?assertEqual({ok, <<"\\377">>}, tmux_text_codec:format(<<"\\\\377">>, Version)),
    ?assertEqual({ok, <<>>}, tmux_text_codec:format(<<>>, Version)),
    lists:foreach(fun(Bad) ->
        ?assertMatch({error, #{code := invalid_observation}},
            tmux_text_codec:format(Bad, Version))
    end, [<<"\\">>, <<"\\z">>, <<"\\r">>, <<0>>, <<"\\000">>]).

framed_columns_preserve_bytes_test() ->
    {ok, Version} = tmux_version:parse(<<"tmux 3.8">>),
    Value = list_to_binary(lists:seq(1, 255)),
    Encoded = binary:replace(binary:replace(binary:replace(Value,
        <<92>>, <<92, 92>>, [global]), <<9>>, <<92, $t>>, [global]),
        <<10>>, <<92, $n>>, [global]),
    Frame = <<"%3\t", Encoded/binary, "\n%4\t\n">>,
    ?assertEqual({ok, [[<<"%3">>, Value], [<<"%4">>, <<>>]]},
        tmux_text_codec:columns(Frame, Version, 2, 2)),
    ?assertEqual({ok, []}, tmux_text_codec:columns(<<>>, Version, 2, 2)),
    lists:foreach(fun(Bad) ->
        ?assertMatch({error, #{code := invalid_observation}},
            tmux_text_codec:columns(Bad, Version, 2, 2))
    end, [<<"%3\tx">>, <<"%3\tx\textra\n">>, <<"%3\n">>,
          <<"%3\t\\z\n">>, <<"%3\t\\\n">>, <<"%3\t", 0, "\n">>]),
    ?assertMatch({error, #{code := capture_limit, limit := max_rows}},
        tmux_text_codec:columns(Frame, Version, 2, 1)).
