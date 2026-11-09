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

fingerprint_test() ->
    Boot = <<"00000000-0000-0000-0000-000000000000">>,
    Identity = {process_identity, 123, Boot, 456},
    {ok, Key} = tmux_identity:fingerprint(Identity),
    ?assertEqual(<<"linux-v1:",
        "6147bddb5be80fdad1f0a76b86da5b68747398c60a433a874e29b190c92c79c6">>,
        Key),
    ?assertEqual(73, byte_size(Key)),
    ?assertEqual({ok, Key}, tmux_identity:fingerprint(Identity)),
    lists:foreach(fun(Other) ->
        ?assertNotEqual({ok, Key}, tmux_identity:fingerprint(Other))
    end, [{process_identity, 124, Boot, 456},
          {process_identity, 123, Boot, 457},
          {process_identity, 123,
              <<"00000000-0000-0000-0000-000000000001">>, 456}]),
    lists:foreach(fun(Invalid) ->
        ?assertEqual({error, #{code => invalid_identity}},
                     tmux_identity:fingerprint(Invalid))
    end, [none, {process_identity, 0, Boot, 456},
          {process_identity, 123, <<"invalid">>, 456},
          {process_identity, 123, Boot, -1}]).
