-module(tmux_control_codec_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

chunk_correlation_test() ->
    ?assertEqual({module, tmux_control_codec}, code:ensure_loaded(tmux_control_codec)),
    Generation = make_ref(),
    Guard = #{generation => Generation, time => 1700000000, number => 42, flags => 1},
    Wire = <<"%begin 1700000000 42 1\n",
             "%begin 1700000000 99 1\n",
             "%end 1700000001 42 1\n",
             "%end 1700000000 43 1\n",
             "%error 1700000000 42 0\n",
             "%session-renamed $1 name\\012bytes\n",
             "raw", 0, 255, 13, "\n",
             "%end 1700000000 42 1\n",
             "%future-event value\\012still-escaped\n">>,
    Expected = [
        {block_begin, Guard},
        {block_data, Guard, <<"%begin 1700000000 99 1\n">>},
        {block_data, Guard, <<"%end 1700000001 42 1\n">>},
        {block_data, Guard, <<"%end 1700000000 43 1\n">>},
        {block_data, Guard, <<"%error 1700000000 42 0\n">>},
        {block_data, Guard, <<"%session-renamed $1 name\\012bytes\n">>},
        {block_data, Guard, <<"raw", 0, 255, 13, "\n">>},
        {block_end, Guard, ok},
        {notification, Generation, <<"%future-event value\\012still-escaped">>}
    ],
    lists:foreach(fun(Cut) ->
        <<First:Cut/binary, Rest/binary>> = Wire,
        ?assertEqual(Expected, decode([First, Rest], Generation))
    end, lists:seq(0, byte_size(Wire))),
    ?assertEqual(Expected, decode([<<Byte>> || <<Byte>> <= Wire], Generation)).

malformed_prefix_and_eof_test() ->
    Generation = make_ref(),
    Guard = #{generation => Generation, time => 1, number => 0, flags => 0},
    Prefix = <<"%begin 1 0 0\n%end 1 0 0\n">>,
    Events = [{block_begin, Guard}, {block_end, Guard, ok}],
    lists:foreach(fun(Bad) ->
        {error, #{code := invalid_control_line, generation := Generation}, Events} =
            tmux_control_codec:feed(tmux_control_codec:new(Generation),
                                    <<Prefix/binary, Bad/binary, "\n">>)
    end, [<<"%begin">>, <<"%begin 1 2">>, <<"%begin 1 2 3 4">>,
          <<"%begin -1 2 1">>, <<"%begin 01 2 1">>,
          <<"%begin 9223372036854775808 2 1">>,
          <<"%begin 1 4294967296 1">>, <<"%begin 1 2 x">>,
          <<"%end 1 2 1">>, <<"%error 1 2 1">>, <<"unframed">>, <<>>]),
    {ok, [], Partial} = tmux_control_codec:feed(tmux_control_codec:new(Generation), <<"%beg">>),
    ?assertMatch({error, #{code := unfinished_control_line}}, tmux_control_codec:finish(Partial)),
    {ok, _, Open} = tmux_control_codec:feed(tmux_control_codec:new(Generation), <<"%begin 1 0 0\n">>),
    ?assertMatch({error, #{code := unfinished_control_block}}, tmux_control_codec:finish(Open)),
    ?assertEqual([{exit, Generation, <<"server exited">>}],
                 decode([<<"%exit server exited\n">>], Generation)),
    ?assertMatch({error, #{code := control_data_after_exit}, [{exit, Generation, <<>>}]},
        tmux_control_codec:feed(tmux_control_codec:new(Generation), <<"%exit\n%future later\n">>)).

line_and_chunk_limits_test() ->
    State = tmux_control_codec:new(make_ref()),
    ?assertMatch({error, #{code := control_chunk_limit}, []},
        tmux_control_codec:feed(State, binary:copy(<<$a>>, 8193))),
    Prefix = <<"%future ">>,
    Bytes = <<Prefix/binary, (binary:copy(<<$a>>, 65536 - byte_size(Prefix)))/binary>>,
    {Full, []} = chunks(Bytes, State),
    ?assertMatch({ok, [{notification, _, Bytes}], _}, tmux_control_codec:feed(Full, <<"\n">>)),
    ?assertMatch({error, #{code := control_line_limit}, []}, tmux_control_codec:feed(Full, <<$a>>)).

block_limit_and_generation_test() ->
    Generation = make_ref(),
    {ok, [Begin], Initial} = tmux_control_codec:feed(tmux_control_codec:new(Generation),
                                                   <<"%begin 1 2 1\n">>),
    ?assertMatch({block_begin, #{generation := Generation}}, Begin),
    Line = <<(binary:copy(<<$a>>, 65535))/binary, "\n">>,
    Full = lists:foldl(fun(_, Previous) ->
        {Next, [{block_data, _, Line}]} = chunks(Line, Previous),
        Next
    end, Initial, lists:seq(1, 16)),
    ?assertMatch({error, #{code := control_output_limit}, []}, tmux_control_codec:feed(Full, <<"a">>)),
    ?assertMatch({error, #{code := control_output_limit}, []}, tmux_control_codec:feed(Full, <<"\n">>)),
    {ok, [], PossibleEnd} = tmux_control_codec:feed(Full, <<"%er">>),
    ?assertMatch({ok, [{block_end, _, error}], _},
                 tmux_control_codec:feed(PossibleEnd, <<"ror 1 2 1\n">>)),
    ?assertMatch({error, #{code := control_output_limit}, []},
                 tmux_control_codec:feed(PossibleEnd, <<"X">>)),
    ?assertMatch({ok, [{block_end, #{generation := Generation}, error}], _},
                 tmux_control_codec:feed(Full, <<"%error 1 2 1\n">>)),
    Other = make_ref(),
    ?assertMatch([{block_begin, #{generation := Other}}, {block_end, _, ok}],
                 decode([<<"%begin 1 2 1\n%end 1 2 1\n">>], Other)).

chunks(Bytes, State) when byte_size(Bytes) > 8192 ->
    <<Chunk:8192/binary, Rest/binary>> = Bytes,
    {ok, Events, Next} = tmux_control_codec:feed(State, Chunk),
    {Final, Tail} = chunks(Rest, Next),
    {Final, Events ++ Tail};
chunks(Bytes, State) ->
    {ok, Events, Next} = tmux_control_codec:feed(State, Bytes),
    {Next, Events}.

decode(Chunks, Generation) ->
    {State, Events} = lists:foldl(fun(Bytes, {Previous, Acc}) ->
        {ok, Batch, Next} = tmux_control_codec:feed(Previous, Bytes),
        {Next, Acc ++ Batch}
    end, {tmux_control_codec:new(Generation), []}, Chunks),
    ?assertEqual(ok, tmux_control_codec:finish(State)),
    Events.
