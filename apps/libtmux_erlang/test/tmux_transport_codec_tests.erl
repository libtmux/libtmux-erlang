-module(tmux_transport_codec_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

open_frame_preserves_bytes_test() ->
    {ok, Packet} = tmux_transport_codec:open(#{
        executable => <<"/bin/printf">>, args => [<<"%s">>, <<"a;#", 255>>],
        cwd => <<"/tmp">>, env => [<<"A=b=c">>], stdin_open => false,
        timeout_ms => 100
    }),
    ?assertMatch(<<$O, 3, 0, 100:32, _/binary>>, Packet),
    ?assertNotEqual(nomatch, binary:match(Packet, <<"a;#", 255>>)),
    ?assertNotEqual(nomatch, binary:match(Packet, <<"A=b=c">>)).

reject_before_encoding_large_or_invalid_input_test() ->
    Base = #{executable => <<"/bin/true">>, args => [], cwd => <<"/tmp">>,
             env => [], stdin_open => false, timeout_ms => 1},
    ?assertMatch({error, #{code := invalid_argument}},
                 tmux_transport_codec:open(Base#{args => [<<"a", 0>>]})),
    ?assertMatch({error, #{code := command_limit}},
                 tmux_transport_codec:open(Base#{args => [binary:copy(<<"a">>, 32768)]})),
    ?assertMatch({error, #{code := command_limit}},
                 tmux_transport_codec:open(Base#{args => lists:duplicate(2048, <<>>)})),
    ?assertMatch({error, #{code := invalid_argument}},
                 tmux_transport_codec:open(Base#{env => [<<"=bad">>]})).

protocol_kinds_and_bounds_test() ->
    ?assertEqual({ok, {started, 123}}, tmux_transport_codec:decode(<<$S, 123:32>>)),
    ?assertEqual({ok, {data, stdout, <<0, 255>>}},
                 tmux_transport_codec:decode(<<$D, 1, 0, 255>>)),
    ?assertEqual({ok, {write_ack, 7, 4096, true}},
                 tmux_transport_codec:decode(<<$A, 7:32, 4096:16, 1>>)),
    ?assertEqual({ok, {retired, 2, 137}},
                 tmux_transport_codec:decode(<<$E, 2, 137:32>>)),
    ?assertEqual({ok, {failed, 4, 0}},
                 tmux_transport_codec:decode(<<$F, 4, 0:32>>)),
    lists:foreach(fun(Packet) ->
        ?assertMatch({error, #{code := invalid_helper_frame}},
                     tmux_transport_codec:decode(Packet))
    end, [<<>>, <<$D, 0, 1>>, <<$D, 1>>, <<$E, 4, 0:32>>,
          <<$A, 1:32, 8193:16, 0>>, <<$F, 5, 0:32>>,
          <<$D, 1, (binary:copy(<<0>>, 8193))/binary>>]).
