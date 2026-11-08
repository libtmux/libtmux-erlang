-module(tmux_key_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

validation_before_dispatch_test() ->
    {ok, Command} = tmux_command:raw(<<"display-message">>, [<<"bound">>]),
    ?assertMatch({error, #{code := invalid_key}},
        tmux_key:bind(invalid, <<>>, Command)),
    ?assertMatch({error, #{code := invalid_key}},
        tmux_key:unbind(invalid, <<0>>)),
    ?assertMatch({error, #{code := invalid_option, path := [table]}},
        tmux_key:bind(invalid, <<"x">>, Command, #{table => <<>>})),
    ?assertMatch({error, #{code := invalid_option, path := [repeat]}},
        tmux_key:bind(invalid, <<"x">>, Command, #{repeat => 2})),
    ?assertMatch({error, #{code := invalid_option, path := [note]}},
        tmux_key:bind(invalid, <<"x">>, Command, #{note => <<0>>})),
    ?assertMatch({error, #{code := invalid_command}},
        tmux_key:bind(invalid, <<"x">>, [])),
    ?assertMatch({error, #{code := invalid_option, path := [table]}},
        tmux_key:clear_table(invalid, <<>>)),
    ?assertMatch({error, #{code := unknown_option}},
        tmux_key:listing(invalid, #{format => <<"#{key_string}">>})),
    ?assertMatch({error, #{code := invalid_key}},
        tmux_key:listing(invalid, #{key => binary:copy(<<$x>>, 129)})).
