-module(tmux_command_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

single_command_test() ->
    {ok, Command} = tmux_command:raw(<<"display-message">>,
        [<<"-p">>, <<"value;">>, <<"slash\\;">>, <<";">>, <<>>]),
    ?assertEqual([<<"display-message">>, <<"-p">>, <<"value\\;">>,
                  <<"slash\\\\;">>, <<"\\;">>, <<>>], tmux_command:argv(Command)),
    ?assertMatch({error, #{code := invalid_command}},
                 tmux_command:raw(<<"display-message;">>, [])),
    ?assertMatch({error, #{code := invalid_command}},
                 tmux_command:raw(<<"-l">>, [])),
    ?assertMatch({error, #{code := invalid_argument}},
                 tmux_command:raw(<<"display-message">>, [<<0>>])).

launch_modes_test() ->
    {ok, [Helper, <<"--exec-one">>, <<"name with spaces;">>]} =
        tmux_command:launch(#{argv => [<<"name with spaces;">>]}),
    ?assert(filelib:is_regular(Helper)),
    ?assertEqual({ok, [<<"/bin/printf">>, <<"%s">>, <<";">>]},
                 tmux_command:launch(#{argv => [<<"/bin/printf">>, <<"%s">>, <<";">>]})),
    ?assertEqual({ok, [<<"printf literal; exit 0">>]},
                 tmux_command:launch(#{shell => <<"printf literal; exit 0">>})),
    ?assertMatch({error, _}, tmux_command:launch(#{argv => []})),
    ?assertMatch({error, _}, tmux_command:launch(#{argv => [<<"a">>], shell => <<"b">>})),
    ?assertEqual({ok, <<"api-##{pane_id},};">>},
                 tmux_command:literal_format(<<"api-#{pane_id},};">>)).

bounded_binary_ownership_test() ->
    Parent = binary:copy(<<"a">>, 1048576),
    Slice = binary:part(Parent, 10, 100),
    ?assert(binary:referenced_byte_size(Slice) > byte_size(Slice)),
    {ok, Command} = tmux_command:raw(<<"display-message">>, [Slice]),
    [_, Argument] = tmux_command:argv(Command),
    ?assertEqual(100, binary:referenced_byte_size(Argument)).

server_utility_commands_test() ->
    {ok, Signal} = tmux_command:wait_for(<<"ready;">>, signal),
    ?assertEqual([<<"wait-for">>, <<"-S">>, <<"--">>, <<"ready\\;">>],
        tmux_command:argv(Signal)),
    {ok, Wait} = tmux_command:wait_for(<<"ready">>, wait),
    ?assertEqual([<<"wait-for">>, <<"--">>, <<"ready">>], tmux_command:argv(Wait)),
    ?assertMatch({error, #{code := invalid_channel}}, tmux_command:wait_for(<<>>, wait)),
    ?assertMatch({error, #{code := invalid_wait_action}},
        tmux_command:wait_for(<<"ready">>, unknown)),
    ?assertMatch({error, #{code := invalid_argument}},
        tmux_command:wait_for(<<0>>, signal)),
    {ok, Source} = tmux_command:source_file(stdin, #{parse_only => true, quiet => true}),
    ?assertEqual([<<"source-file">>, <<"-n">>, <<"-q">>, <<"--">>, <<"-">>],
        tmux_command:argv(Source)),
    ?assertMatch({error, #{code := invalid_source_path}},
        tmux_command:source_file(<<"relative.conf">>, #{})),
    ?assertMatch({error, #{code := invalid_option, path := [parse_only]}},
        tmux_command:source_file(stdin, #{parse_only => yes})),
    ?assertMatch({error, #{code := unknown_option, path := [expand_formats]}},
        tmux_command:source_file(stdin, #{expand_formats => true})).

literal_time_limit_test() ->
    Boundary = <<$%, (binary:copy(<<$a>>, 8190))/binary>>,
    ?assertMatch({ok, _}, tmux_command:literal_format(Boundary, time)),
    ?assertMatch({error, #{code := format_limit, max_bytes := 8191}},
        tmux_command:literal_format(<<Boundary/binary, $a>>, time)),
    ?assertMatch({ok, _}, tmux_command:literal_format(binary:copy(<<$a>>, 10000), time)),
    WithHash = <<$%, $#, (binary:copy(<<$a>>, 8188))/binary>>,
    ?assertMatch({ok, _}, tmux_command:literal_format(WithHash, time)),
    ?assertMatch({error, #{code := format_limit}},
        tmux_command:literal_format(<<WithHash/binary, $a>>, time)).

config_render_validation_test() ->
    ?assertMatch({error, #{code := invalid_command}}, tmux_command:to_config(invalid)),
    {ok, Large} = tmux_command:raw(<<"set-option">>,
        [<<"-g">>, <<"@bytes">>, binary:copy(<<255>>, 10000)]),
    ?assertMatch({error, #{code := command_limit}}, tmux_command:to_config(Large)).
