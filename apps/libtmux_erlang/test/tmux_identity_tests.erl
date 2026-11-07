-module(tmux_identity_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

current_process_test() ->
    Pid = list_to_integer(os:getpid()),
    {ok, Identity} = tmux_identity:observe(Pid),
    ?assertEqual(ok, tmux_identity:check(Identity, Pid)),
    ?assertMatch({error, #{code := stale_server}},
                 tmux_identity:check(Identity, Pid + 1)),
    ?assertMatch({error, #{code := invalid_identity}}, tmux_identity:check(#{}, Pid)),
    ?assertMatch({error, #{code := invalid_pid}}, tmux_identity:observe(0)),
    ?assertMatch({error, #{code := invalid_pid}}, tmux_identity:observe(<<"self">>)).
