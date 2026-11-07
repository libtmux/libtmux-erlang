-module(tmux_option_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

scope_validation_before_dispatch_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%1">>}),
    ?assertMatch({error, #{code := wrong_option_scope}},
        tmux_option:set(Pane, <<"exit-empty">>, <<"off">>)),
    ?assertMatch({error, #{code := hook_requires_api}},
        tmux_option:set({session_defaults, invalid}, <<"pane-died">>, <<"kill-server">>)),
    ?assertMatch({error, #{code := unknown_tmux_option}},
        tmux_option:get({server, invalid}, <<"exit-em">>, #{})),
    ?assertMatch({error, #{code := invalid_option_key}},
        tmux_option:get(Pane, <<"@ambiguous[0]">>, #{})),
    ?assertMatch({error, #{code := array_index_required}},
        tmux_option:set({session_defaults, invalid}, <<"update-environment">>, <<"A B">>)),
    ?assertMatch({error, #{code := invalid_option_value}},
        tmux_option:set(Pane, <<"@value">>, <<0>>)),
    ?assertMatch({error, #{code := unknown_option}},
        tmux_option:get(Pane, <<"@value">>, #{quiet => true})).

catalogue_version_boundary_test() ->
    {ok, Old} = tmux_version:parse(<<"tmux 3.3">>),
    {ok, New} = tmux_version:parse(<<"tmux 3.8">>),
    {ok, Future} = tmux_version:parse(<<"tmux 4.0">>),
    ?assertMatch({ok, #{scopes := [server], array := false}},
        tmux_option:describe(Old, <<"exit-empty">>)),
    ?assertMatch({error, #{code := unsupported_tmux_option}},
        tmux_option:describe(Old, <<"pane-scrollbars-style">>)),
    ?assertMatch({ok, #{scopes := [window, pane]}},
        tmux_option:describe(New, <<"pane-scrollbars-style">>)),
    ?assertMatch({error, #{code := unsupported_option_catalogue}},
        tmux_option:describe(Future, <<"exit-empty">>)).

array_observation_codec_test() ->
    Name = <<"update-environment">>,
    Output = <<"update-environment[0]* ''\n",
               "update-environment[7]* \"a\\n\\t\\377\\\\\\\"$#{x}\"\n">>,
    ?assertEqual({ok, #{0 => <<>>, 7 => <<"a\n\t", 255, $\\, $", "$#{x}">>}},
        tmux_option_codec:array(Name, Output)),
    ?assertEqual(none, tmux_option_codec:array(Name, <<>>)),
    ?assertEqual({ok, #{}}, tmux_option_codec:array(Name, <<Name/binary, "\n">>)),
    lists:foreach(fun(Bad) ->
        ?assertMatch({error, #{code := invalid_observation}},
            tmux_option_codec:array(Name, Bad))
    end, [<<"other[0] x\n">>, <<"update-environment[0] 'broken\n">>,
          <<"update-environment[0] x\nupdate-environment[0] y\n">>,
          <<"update-environment[0] \\\n">>]).
