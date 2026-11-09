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

sequence_separators_test() ->
    {ok, First} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<"literal;">>]),
    {ok, Last} = tmux_command:raw(<<"display-message">>, [<<"-p">>, <<";">>]),
    {ok, Sequence} = tmux_command:sequence([First, Last]),
    ?assertEqual([<<"display-message">>, <<"-p">>, <<"literal\\;">>, <<";">>,
        <<"display-message">>, <<"-p">>, <<"\\;">>], tmux_command:argv(Sequence)),
    ?assertEqual({ok, Sequence}, tmux_command:validate(Sequence)),
    ?assertEqual(tmux_command:to_config([First, Last]),
        tmux_command:to_config(Sequence)),
    ?assertEqual(none, tmux_command:provenance(Sequence)).

sequence_bounds_and_origins_test() ->
    {ok, Command} = tmux_command:raw(<<"display-message">>, []),
    ?assertMatch({ok, _}, tmux_command:sequence(lists:duplicate(256, Command))),
    ?assertMatch({error, #{code := command_limit}},
        tmux_command:sequence(lists:duplicate(257, Command))),
    ?assertMatch({error, _}, tmux_command:sequence([])),
    ?assertMatch({error, _}, tmux_command:sequence([Command | invalid])),
    {ok, Sequence} = tmux_command:sequence([Command]),
    ?assertMatch({error, _}, tmux_command:sequence([Sequence])),
    {ok, Large} = tmux_command:raw(<<"display-message">>, [binary:copy(<<$a>>, 17000)]),
    ?assertMatch({error, #{code := command_limit}}, tmux_command:sequence([Large, Large])),
    Origin = make_ref(),
    {ok, Bound} = tmux_command:generated(session_rename, Origin, [<<"-t">>, <<"$1:">>, <<"x">>]),
    {ok, BoundSequence} = tmux_command:sequence([Command, Bound]),
    ?assertEqual(#{origin => Origin, kind => sequence},
        tmux_command:provenance(BoundSequence)),
    {ok, Foreign} = tmux_command:generated(session_rename, make_ref(),
        [<<"-t">>, <<"$2:">>, <<"y">>]),
    ?assertMatch({error, #{code := different_owner}}, tmux_command:sequence([Bound, Foreign])).

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

config_sequence_boundaries_test() ->
    {ok, Command} = tmux_command:raw(<<"display-message">>, []),
    ?assertMatch({ok, _}, tmux_command:to_config(lists:duplicate(256, Command))),
    ?assertMatch({error, #{code := command_limit}},
        tmux_command:to_config(lists:duplicate(257, Command))),
    ?assertMatch({error, #{code := invalid_command}}, tmux_command:to_config([])),
    ?assertMatch({error, #{code := invalid_command}},
        tmux_command:to_config([[Command]])),
    ?assertMatch({error, #{code := invalid_command, reason := invalid_command_list}},
        tmux_command:to_config([Command | invalid])),
    {ok, Large} = tmux_command:raw(<<"display-message">>,
        [binary:copy(<<$a>>, 17000)]),
    ?assertMatch({error, #{code := command_limit}},
        tmux_command:to_config([Large, Large])).

captured_command_builders_test() ->
    Origin = make_ref(),
    Snapshot = make_ref(),
    {ok, Session0} = tmux_model:session(#{id => <<"$7">>}),
    Session = tmux_model:bind(Session0, Origin, Snapshot),
    {ok, Rename} = tmux_session:rename_command(Session, <<"api-#{pid}">>),
    ?assertEqual([<<"rename-session">>, <<"-t">>, <<"$7:">>, <<"--">>, <<"api-##{pid}">>],
                 tmux_command:argv(Rename)),
    ?assertEqual(#{origin => Origin, kind => session_rename}, tmux_command:provenance(Rename)),
    ?assertEqual({ok, Rename}, tmux_command:validate(Rename)),
    ?assertEqual({ok, <<"rename-session \"-t\" \"\\0447:\" \"--\" \"api-##{pid}\"">>},
                 tmux_command:to_config(Rename)),
    {ok, Pane0} = tmux_model:pane(#{id => <<"%8">>}),
    Pane = tmux_model:bind(Pane0, Origin, Snapshot),
    {ok, Resize} = tmux_pane:resize_command(Pane, #{width => 90, height => 20}),
    ?assertEqual([<<"resize-pane">>, <<"-x">>, <<"90">>, <<"-y">>, <<"20">>, <<"-t">>, <<"%8">>],
                 tmux_command:argv(Resize)),
    ?assertEqual(#{origin => Origin, kind => pane_resize}, tmux_command:provenance(Resize)),
    ?assertEqual({ok, Resize}, tmux_command:validate(Resize)),
    {ok, Raw} = tmux_command:raw(<<"resize-pane">>, tl(tmux_command:argv(Resize))),
    ?assertEqual(none, tmux_command:provenance(Raw)),
    ?assertMatch({error, #{code := detached_reference}},
                 tmux_session:rename_command(Session0, <<"main">>)),
    ?assertMatch({error, #{code := wrong_target_kind}}, tmux_pane:resize_command(Session, #{width => 90})),
    ?assertMatch({error, #{code := empty_resize}}, tmux_pane:resize_command(Pane, #{})).
