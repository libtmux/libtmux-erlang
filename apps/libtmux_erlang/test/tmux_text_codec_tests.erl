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
