-module(tmux_control_codec_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1, native_frames/1]).

%% Outer: real control protocol over the bounded helper, with owned cleanup.
%% This qualifies framing; it does not expose a persistent public dispatcher.
all() -> [native_frames].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux");
        Path -> Path
    end,
    true = is_list(Executable),
    [{executable, unicode:characters_to_binary(Executable)} | Config].

end_per_suite(_) -> ok = application:stop(libtmux_erlang).

native_frames(Config) ->
    Executable = proplists:get_value(executable, Config),
    {ok, Fixture} = tmux_test_fixture:start(Executable),
    try
        #{socket := Socket, server_pid := Server, server_identity := ServerIdentity} =
            tmux_test_fixture:info(Fixture),
        {ok, _} = tmux_test_fixture:command(Fixture,
            [<<"new-session">>, <<"-d">>, <<"-s">>, <<"codec">>, <<"/bin/cat">>]),
        {ok, Channel} = tmux_transport:start_channel(Executable,
            [<<"-u">>, <<"-C">>, <<"-N">>, <<"-S">>, Socket,
             <<"attach-session">>, <<"-f">>, <<"no-output">>, <<"-t">>, <<"=codec">>], #{}),
        try
            {ok, #{child_pid := Child, helper_pid := Helper}} =
                tmux_transport:await_started(Channel, 900),
            ChildIdentity = tmux_test_fixture:process_identity(Child),
            HelperIdentity = tmux_test_fixture:process_identity(Helper),
            Script = <<"display-message -p 101 ; display-message -p 102\n",
                       "display-message -p 201 ; no-such-tmux-codec-command ; display-message -p 202\n",
                       "display-message -p 301 ; select-pane -t %4294967295 ; display-message -p 302\n",
                       "display-message -p 401\ndetach-client\n">>,
            {ok, Write} = tmux_transport:write(Channel, Script),
            receive
                {tmux_transport, Channel, {write_ack, Write, Size}} ->
                    Size = byte_size(Script),
                    ok = tmux_transport:ack_write(Channel, Write)
            after 900 -> ct:fail(control_write_timeout)
            end,
            Generation = make_ref(),
            Events = drain(Channel, tmux_control_codec:new(Generation),
                erlang:monotonic_time(millisecond) + 900, 65536, []),
            {ok, #{cleanup := complete, exit_status := 0}} = tmux_transport:await(Channel, 900),
            false = tmux_test_fixture:same_process(Child, ChildIdentity),
            false = tmux_test_fixture:same_process(Helper, HelperIdentity),
            true = tmux_test_fixture:same_process(Server, ServerIdentity),
            true = lists:any(fun
                ({notification, G, <<"%session-changed ", _/binary>>}) -> G =:= Generation;
                (_) -> false
            end, Events),
            [{exit, Generation, _}] = [E || {exit, _, _} = E <- Events],
            Blocks = blocks(Events, none, [], []),
            [{0, ok, <<>>} | Commands] = Blocks,
            [{1, ok, <<"101\n">>}, {1, ok, <<"102\n">>},
             {1, error, <<"parse error: ", _/binary>>}, {1, ok, <<"301\n">>},
             {1, error, _}, {1, ok, <<"401\n">>}, {1, ok, <<>>}] = Commands
        after ok = tmux_transport:close(Channel)
        end
    after ok = tmux_test_fixture:ensure_closed(Fixture)
    end.

drain(Channel, Codec, Deadline, Budget, Acc) when Budget >= 0 ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {tmux_transport, Channel, {data, stdout, Sequence, Bytes}} ->
            true = byte_size(Bytes) =< Budget,
            {ok, Events, Next} = tmux_control_codec:feed(Codec, Bytes),
            ok = tmux_transport:ack(Channel, stdout, Sequence),
            drain(Channel, Next, Deadline, Budget - byte_size(Bytes), lists:reverse(Events, Acc));
        {tmux_transport, Channel, {data, stderr, _, Bytes}} -> ct:fail({control_stderr, Bytes});
        {tmux_transport, Channel, {eof, stdout}} ->
            ok = tmux_control_codec:finish(Codec),
            lists:reverse(Acc)
    after Remaining -> ct:fail(control_read_timeout)
    end.

blocks([], none, [], Acc) -> lists:reverse(Acc);
blocks([{block_begin, Guard} | Rest], none, [], Acc) -> blocks(Rest, Guard, [], Acc);
blocks([{block_data, Guard, Bytes} | Rest], Guard, Parts, Acc) ->
    blocks(Rest, Guard, [Bytes | Parts], Acc);
blocks([{block_end, #{flags := Flags} = Guard, Outcome} | Rest], Guard, Parts, Acc) ->
    blocks(Rest, none, [], [{Flags, Outcome, iolist_to_binary(lists:reverse(Parts))} | Acc]);
blocks([{notification, _, _} | Rest], Guard, Parts, Acc) -> blocks(Rest, Guard, Parts, Acc);
blocks([{exit, _, _} | Rest], none, [], Acc) -> blocks(Rest, none, [], Acc).
