-module(tmux_model_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

constructor_validation_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%7">>, width => 120.0}),
    ?assertEqual(120, tmux_model:get(width, Pane)),
    ?assertEqual(not_loaded, tmux_model:get(current_command, Pane)),
    ?assertEqual(none, tmux_model:origin(Pane)),
    ?assertEqual({ok, Pane}, tmux_model:validate(Pane)),
    ?assertMatch({error, #{code := invalid_value, path := [id]}},
                 tmux_model:pane(#{id => <<"@7">>})),
    ?assertMatch({error, #{code := invalid_value, path := [width]}},
                 tmux_model:pane(#{id => <<"%7">>, width => -1})),
    ?assertMatch({error, #{code := invalid_value}},
                 tmux_model:pane(#{id => <<"%7">>, width => 1.5})),
    ?assertMatch({error, #{code := invalid_value}},
                 tmux_model:pane(#{id => <<"%7">>, width => 9007199254740992})),
    ?assertMatch({error, #{code := unknown_field}},
                 tmux_model:pane(#{id => <<"%7">>, origin => make_ref()})),
    ?assertMatch({error, #{code := invalid_row}},
                 tmux_model:validate({pane, <<"%7">>})).

absence_and_byte_paths_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%1">>, exit_status => none, pid => none,
                                  current_path => <<"/tmp/", 255>>}),
    ?assertEqual(none, tmux_model:get(exit_status, Pane)),
    ?assertEqual(none, tmux_model:get(pid, Pane)),
    ?assertMatch({error, #{code := invalid_value, path := [pid]}},
                 tmux_model:pane(#{id => <<"%1">>, pid => 0})),
    ?assertEqual(not_loaded, tmux_model:get(dead, Pane)),
    ?assertEqual(<<"/tmp/", 255>>, tmux_model:get(current_path, Pane)),
    ?assertMatch({error, #{code := invalid_value, path := [title]}},
                 tmux_model:pane(#{id => <<"%1">>, title => <<255>>})),
    ?assertMatch({error, #{code := invalid_value}},
                 tmux_model:pane(#{id => <<"%1">>, active => none})).

session_attachment_invariant_test() ->
    {ok, Session} = tmux_model:session(#{id => <<"$1">>, attached_count => 3}),
    ?assertEqual(true, tmux_model:get(attached, Session)),
    ?assertEqual(3, tmux_model:get(attached_count, Session)),
    ?assertMatch({error, #{code := inconsistent_derived_value}},
                 tmux_model:session(#{id => <<"$1">>, attached_count => 3,
                                      attached => false})).

link_identity_fields_test() ->
    ?assertMatch({error, #{code := required_field}},
                 tmux_model:window_link(#{session_id => <<"$0">>,
                                          window_id => <<"@0">>})),
    {ok, A} = tmux_model:window_link(#{session_id => <<"$0">>,
                                      window_id => <<"@0">>, index => 0}),
    {ok, B} = tmux_model:window_link(#{session_id => <<"$0">>,
                                      window_id => <<"@0">>, index => 2}),
    ?assertNotEqual(tmux_model:to_map(A), tmux_model:to_map(B)),
    ?assertEqual(tmux_model:get(window_id, A), tmux_model:get(window_id, B)).
