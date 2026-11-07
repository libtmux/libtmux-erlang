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
