-module(tmux_capability_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

native_catalogue_test() ->
    {ok, Floor} = tmux_version:parse(<<"tmux 3.3">>),
    {ok, NewKeys} = tmux_version:parse(<<"tmux 3.4">>),
    {ok, Latest} = tmux_version:parse(<<"tmux 3.8">>),
    {ok, #{argument_spec := FloorKeys, source := Source}} =
        tmux_capability:command(Floor, <<"send-keys">>),
    ?assertEqual(nomatch, binary:match(FloorKeys, <<"K">>)),
    ?assertEqual(<<"cmd-send-keys.c">>, maps:get(file, Source)),
    ?assertEqual(64, byte_size(maps:get(sha256, Source))),
    {ok, #{argument_spec := ClientKeys}} =
        tmux_capability:command(NewKeys, <<"send-keys">>),
    ?assertNotEqual(nomatch, binary:match(ClientKeys, <<"K">>)),
    {ok, #{argument_spec := Formats}} =
        tmux_capability:command(Latest, <<"list-keys">>),
    ?assertNotEqual(nomatch, binary:match(Formats, <<"F:">>)),
    {ok, Commands} = tmux_capability:commands(Floor),
    ?assertEqual(Commands, lists:usort(Commands)),
    ?assert(lists:member(<<"bind-key">>, Commands)),
    ?assertMatch({error, #{code := unknown_command}},
        tmux_capability:command(Floor, <<"lsk">>)),
    {ok, Uncatalogued} = tmux_version:parse(<<"tmux 3.8a">>),
    ?assertMatch({error, #{code := unsupported_command_catalogue}},
        tmux_capability:commands(Uncatalogued)),
    ?assertEqual(ok, tmux_capability:require(Uncatalogued, layout_json)),
    {ok, Tracking} = tmux_version:parse(<<"tmux next-3.8">>),
    ?assertMatch({error, #{code := unsupported_command_catalogue}},
        tmux_capability:commands(Tracking)),
    ?assertEqual(ok, tmux_capability:require(Tracking, layout_json)),
    ?assertEqual(7, length(tmux_capability:profiles())).

feature_gates_test() ->
    {ok, Floor} = tmux_version:parse(<<"tmux 3.3">>),
    {ok, ClientKeys} = tmux_version:parse(<<"tmux 3.4">>),
    {ok, Formats} = tmux_version:parse(<<"tmux 3.7c">>),
    {ok, Latest} = tmux_version:parse(<<"tmux 3.8">>),
    ?assertMatch({ok, #{minimum := {3, 8}}}, tmux_capability:describe(layout_json)),
    ?assertEqual({error, #{code => unsupported_capability,
        capability => layout_json, minimum => {3, 8}}},
        tmux_capability:require(Floor, layout_json)),
    ?assertEqual(ok, tmux_capability:require(Latest, layout_json)),
    ?assertEqual(ok, tmux_capability:require(Floor, native_list_filter)),
    ?assertMatch({error, #{code := unsupported_capability}},
        tmux_capability:require(Floor, send_client_keys)),
    ?assertEqual(ok, tmux_capability:require(ClientKeys, send_client_keys)),
    ?assertEqual(ok, tmux_capability:require(Formats, key_list_format)),
    ?assertMatch({error, #{code := unknown_capability}},
        tmux_capability:describe(unknown)),
    ?assertMatch({error, #{code := invalid_version}},
        tmux_capability:require(invalid, layout_json)).
