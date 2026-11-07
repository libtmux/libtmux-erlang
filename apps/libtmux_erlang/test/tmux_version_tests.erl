-module(tmux_version_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

floor_and_numeric_order_test() ->
    {ok, Floor} = tmux_version:parse(<<"tmux 3.3\n">>),
    {ok, Older} = tmux_version:parse(<<"tmux 3.2a">>),
    {ok, Later} = tmux_version:parse(<<"tmux 3.10">>),
    ?assert(tmux_version:at_least(Floor, {3, 3})),
    ?assertNot(tmux_version:at_least(Older, {3, 3})),
    ?assert(tmux_version:at_least(Later, {3, 8})),
    ?assertMatch({ok, _}, tmux_version:require(<<"tmux 3.3">>)),
    ?assertMatch({error, {unsupported_tmux_version, _}},
                 tmux_version:require(<<"tmux 3.2a">>)).

malformed_and_tracking_versions_test() ->
    ?assertMatch({ok, #{patch := <<"a">>}},
                 tmux_version:parse(<<"tmux 3.3a">>)),
    ?assertMatch({ok, #{tracking := true}},
                 tmux_version:parse(<<"tmux next-3.8">>)),
    lists:foreach(
        fun(Value) ->
            ?assertMatch({error, {invalid_tmux_version, _}},
                         tmux_version:parse(Value))
        end,
        [<<"3.8">>, <<"tmux 3.8 garbage">>, <<"tmux 3.x">>,
         <<"tmux 3.8\ntmux 3.3">>, <<0>>, binary:copy(<<"9">>, 128)]
    ).
