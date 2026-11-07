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
