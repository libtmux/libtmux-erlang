-module(tmux_domain_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

validation_before_dispatch_test() ->
    ?assertMatch({error, #{code := unknown_option, path := [unknown]}},
        tmux_session:create(invalid_server, #{unknown => true})),
    ?assertMatch({error, #{code := invalid_option, path := [size]}},
        tmux_pane:split(invalid_row, #{size => {percent, 101}})),
    ?assertMatch({error, #{code := invalid_environment}},
        tmux_window:create(invalid_row, #{env => #{<<"invalid=key">> => <<"value">>}})),
    ?assertMatch({error, #{code := command_limit}},
        tmux_pane:send_text(invalid_row, binary:copy(<<1>>, 2001))),
    ?assertMatch({error, #{code := invalid_key}}, tmux_pane:send_keys(invalid_row, [no_such_key])).

completed_mutation_survives_read_failure_test() ->
    Result = #{stdout => <<"$2\n">>, exit_status => 0, cleanup => complete},
    ?assertMatch({error, #{code := post_action_read_failed, mutation := completed,
                          created_id := <<"$2">>, command_result := Result}},
        tmux_observe:created(invalid_server, session, Result)).

geometry_validation_before_dispatch_test() ->
    ?assertMatch({error, #{code := empty_resize}},
        tmux_pane:resize(invalid_row, #{})),
    ?assertMatch({error, #{code := invalid_option, path := [width]}},
        tmux_pane:resize(invalid_row, #{width => 0})),
    ?assertMatch({error, #{code := unknown_option, path := [zoom]}},
        tmux_pane:resize(invalid_row, #{zoom => true})),
    ?assertMatch({error, #{code := invalid_layout}},
        tmux_window:select_layout(invalid_row, unknown_layout)),
    ?assertMatch({error, #{code := invalid_value, path := [layout]}},
        tmux_window:select_layout(invalid_row, <<255>>)),
    ?assertMatch({error, #{code := command_limit, path := [layout]}},
        tmux_window:select_layout(invalid_row, binary:copy(<<255>>, 32769))),
    ?assertMatch({error, #{code := invalid_argument, path := [layout]}},
        tmux_window:select_layout(invalid_row, <<0>>)),
    lists:foreach(fun(Layout) ->
        ?assertMatch({error, #{code := invalid_layout, path := [layout]}},
            tmux_window:select_layout(invalid_row, Layout))
    end, [<<>>, <<"a">>, <<"-n">>, <<"t">>, <<"tiled;">>,
          <<"tiled; kill-server;">>, <<"not-a-layout">>, <<"1234,">>]).
