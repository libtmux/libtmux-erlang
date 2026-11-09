-module(tmux_workspace_layout_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

saved_cells_test() ->
    Legacy = <<"09fa,80x24,0,0{39x24,0,0,1,40x24,40,0,2}">>,
    Expected = #{<<"%1">> => {39, 24}, <<"%2">> => {40, 24}},
    ?assertEqual(Expected, tmux_workspace_layout:cells(Legacy)),
    Json = <<"{\"V\":2,\"L\":{\"t\":\"h\",\"w\":80,\"h\":24,\"c\":[",
        "{\"t\":\"p\",\"w\":39,\"h\":24,\"I\":\"%1\"},",
        "{\"t\":\"p\",\"w\":40,\"h\":24,\"I\":\"%2\"}]}}">>,
    ?assertEqual(Expected, tmux_workspace_layout:cells(Json)),
    Float = <<"{\"V\":2,\"L\":{\"t\":\"p\",\"w\":80,\"h\":24,",
        "\"I\":\"%1\",\"z\":0}}">>,
    ?assertEqual(#{<<"%1">> => floating}, tmux_workspace_layout:cells(Float)),
    ?assertEqual(none, tmux_workspace_layout:split(floating)),
    ?assertEqual({horizontal, {1, 1}, {1, 1}},
        tmux_workspace_layout:split({3, 1})),
    ?assertEqual(none, tmux_workspace_layout:split({1, 1})),
    ?assertEqual({vertical, {1, 12}, {1, 11}},
        tmux_workspace_layout:split({1, 24})).

malformed_layout_test() ->
    lists:foreach(fun(Layout) ->
        ?assertThrow({workspace_error, _}, tmux_workspace_layout:cells(Layout))
    end, [<<>>, <<"09fa,80x24,0,0{39x24,0,0,1,40x24,40,0,2">>,
        <<"0000,80x24,0,0,1">>, <<"{\"V\":3,\"L\":{}}">>,
        <<"{\"V\":2,\"L\":{\"t\":\"p\",\"w\":0,\"h\":24,\"I\":\"%1\"}}">>,
        <<"{\"V\":2,\"L\":{\"t\":\"h\",\"w\":80,\"h\":24,\"c\":[",
          "{\"t\":\"p\",\"w\":39,\"h\":24,\"I\":\"%1\"},",
          "{\"t\":\"p\",\"w\":40,\"h\":24,\"I\":\"%1\"}]}}">>,
        binary:copy(<<"x">>, 262145)]).
