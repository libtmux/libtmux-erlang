-module(tmux_version_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

release_stage_order_test() ->
    Names = [<<"next-3.8">>, <<"3.8-rc1">>, <<"3.8-rc2">>,
             <<"3.8-rc10">>, <<"3.8">>, <<"3.8a">>, <<"3.9">>],
    Versions = [begin {ok, V} = tmux_version:parse(<<"tmux ", Name/binary>>), V
                end || Name <- Names],
    lists:foreach(fun({Index, Left}) ->
        lists:foreach(fun({OtherIndex, Right}) ->
            ?assertEqual(Index >= OtherIndex,
                tmux_version:at_least(Left, maps:get(raw, Right)))
        end, lists:enumerate(Versions))
    end, lists:enumerate(Versions)),
    {ok, Patch} = tmux_version:parse(<<"tmux 3.6a">>),
    ?assert(tmux_version:at_least(Patch, <<"3.6a">>)),
    {ok, BeforePatch} = tmux_version:parse(<<"tmux 3.6">>),
    ?assertNot(tmux_version:at_least(BeforePatch, <<"3.6a">>)),
    {ok, Tracking} = tmux_version:parse(<<"tmux next-3.8">>),
    ?assertNot(tmux_version:at_least(Tracking, {3, 8})),
    lists:foreach(fun(Name) ->
        ?assertMatch({error, {invalid_tmux_version, _}},
            tmux_version:parse(<<"tmux ", Name/binary>>))
    end, [<<"3.8-rc">>, <<"3.8-rc0">>, <<"3.8-rc-1">>,
          <<"next-3.8a">>, <<"next-3.8-rc1">>, <<"3.8a-rc1">>]).

floor_and_numeric_order_test() ->
    {ok, Floor} = tmux_version:parse(<<"tmux 3.3\n">>),
    {ok, Older} = tmux_version:parse(<<"tmux 3.2a">>),
    {ok, Later} = tmux_version:parse(<<"tmux 3.10">>),
    ?assert(tmux_version:at_least(Floor, {3, 3})),
    ?assertNot(tmux_version:at_least(Older, {3, 3})),
    ?assert(tmux_version:at_least(Later, {3, 8})),
    ?assertMatch({error, {unsupported_tmux_version, _}},
                 tmux_version:require(<<"tmux 3.3">>)),
    lists:foreach(
        fun(Release) ->
            ?assertMatch({ok, _},
                         tmux_version:require(<<"tmux ", Release/binary>>))
        end,
        [<<"3.3a">>, <<"3.4">>, <<"3.5">>, <<"3.5a">>, <<"3.6">>,
         <<"3.6a">>, <<"3.6b">>, <<"3.7">>, <<"3.7a">>, <<"3.7b">>,
         <<"3.7c">>, <<"3.8">>]
    ),
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
