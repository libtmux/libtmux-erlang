-module(tmux_buffer_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

validation_before_dispatch_test() ->
    lists:foreach(fun(Name) ->
        ?assertMatch({error, #{code := invalid_buffer_name}},
            tmux_buffer:show(invalid_server, Name))
    end, [<<>>, <<0>>, invalid]),
    ?assertMatch({error, #{code := invalid_buffer_data}},
        tmux_buffer:load(invalid_server, <<"name">>, not_bytes)),
    ?assertMatch({error, #{code := command_limit}},
        tmux_buffer:load(invalid_server, <<"name">>, binary:copy(<<1>>, 262145))),
    ?assertMatch({error, #{code := invalid_option, path := [max_bytes]}},
        tmux_buffer:show(invalid_server, <<"name">>, #{max_bytes => -1})),
    ?assertMatch({error, #{code := unknown_option, path := [stdin]}},
        tmux_buffer:show(invalid_server, <<"name">>, #{stdin => <<>>})),
    ?assertMatch({error, #{code := same_buffer_name}},
        tmux_buffer:rename(invalid_server, <<"name">>, <<"name">>)),
    ?assertMatch({error, #{code := invalid_option, path := [sanitize]}},
        tmux_buffer:paste(invalid_row, latest, #{sanitize => yes})),
    ?assertMatch({error, #{code := invalid_option, path := [separator]}},
        tmux_buffer:paste(invalid_row, latest, #{separator => <<0>>})).

length_framed_names_test() ->
    {ok, V33} = tmux_version:parse(<<"tmux 3.3">>),
    {ok, V34} = tmux_version:parse(<<"tmux 3.4">>),
    ?assertEqual({ok, [#{name => <<"a\nb:5">>, size => 2, created => 123},
                       #{name => <<"x">>, size => 7, created => 124}]},
        tmux_buffer_codec:list(<<"5:2:123:a\nb:5\n1:7:124:x\n">>, V33)),
    ?assertEqual({ok, [#{name => <<"x\r\\r $HOME">>, size => 7, created => 123}]},
        tmux_buffer_codec:list(<<"10:7:123:x\\r\\\\r\\ \\\\$HOME\n">>, V34)),
    ?assertEqual({ok, []}, tmux_buffer_codec:list(<<>>, V33)),
    lists:foreach(fun(Bytes) ->
        ?assertMatch({error, #{code := invalid_buffer_observation}},
            tmux_buffer_codec:list(Bytes, V33))
    end, [<<"1:7:1:x">>, <<"2:7:1:x\n">>, <<"0:7:1:\n">>,
          <<"1:-7:1:x\n">>, <<"1:7:1:x\n1:8:2:x\n">>,
          <<"18446744073709551616:7:1:x\n">>]).
