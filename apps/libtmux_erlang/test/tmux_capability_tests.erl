-module(tmux_capability_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

shared_gate_registry_test() ->
    {ok, Old} = tmux_version:parse(<<"tmux 3.3a">>),
    {ok, Current} = tmux_version:parse(<<"tmux 3.8">>),
    Features = tmux_capability:features(),
    ?assertEqual(Features, lists:usort(Features)),
    lists:foreach(fun(Feature) ->
        {ok, Info} = tmux_capability:describe(Feature),
        ?assert(is_binary(maps:get(minimum, Info))),
        ?assertMatch([_ | _], maps:get(apis, Info)),
        ?assertMatch({ok, #{supported := true}},
            tmux_capability:decision(Current, Feature))
    end, Features),
    lists:foreach(fun(Feature) ->
        ?assertMatch({ok, #{supported := false}},
            tmux_capability:decision(Old, Feature))
    end, [paste_sanitize, cleaned_names, rename_replaces,
          strict_named_target, control_no_detach]),
    ?assertMatch({error, #{code := unknown_capability}},
        tmux_capability:decision(Current, unknown)),
    #{schema := <<"libtmux-capabilities/1">>, port := <<"erlang">>,
      floor := #{minimum := <<"3.3a">>}, capabilities := Manifest} =
        tmux_capability:manifest(),
    [KeepAttached] = [Entry || #{id := <<"control-no-detach-on-destroy">>} = Entry <- Manifest],
    ?assertMatch(#{handling := <<"fallback">>, since := <<"3.6">>,
                   fallback := <<"omit-no-detach-on-destroy">>}, KeepAttached),
    ?assertNot(maps:is_key(error, KeepAttached)),
    [Stream] = [Entry || #{id := <<"control-stream">>} = Entry <- Manifest],
    ?assertMatch(#{handling := <<"refuse">>, since := <<"3.3a">>,
                   apis := [<<"tmux_stream:subscribe/3">>]}, Stream),
    [Layout] = [Entry || #{id := <<"layout-json">>} = Entry <- Manifest],
    ?assertMatch(#{handling := <<"refuse">>, since := <<"3.8">>,
                   error := <<"unsupported_capability">>}, Layout).

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
    ?assertMatch({error, #{code := unsupported_capability}},
        tmux_capability:require(Tracking, layout_json)),
    {ok, Candidate} = tmux_version:parse(<<"tmux 3.8-rc2">>),
    ?assertMatch({error, #{code := unsupported_command_catalogue}},
        tmux_capability:commands(Candidate)),
    ?assertMatch({error, #{code := unsupported_capability}},
        tmux_capability:require(Candidate, layout_json)),
    lists:foreach(fun(Release) ->
        {ok, Version} = tmux_version:require(<<"tmux ", Release/binary>>),
        ?assertMatch({ok, _},
            tmux_capability:command(Version, <<"send-keys">>))
    end, [<<"3.3a">>, <<"3.4">>, <<"3.5">>, <<"3.5a">>, <<"3.6">>,
          <<"3.6a">>, <<"3.6b">>, <<"3.7">>, <<"3.7a">>, <<"3.7b">>,
          <<"3.7c">>, <<"3.8">>]).

feature_gates_test() ->
    {ok, Floor} = tmux_version:parse(<<"tmux 3.3">>),
    {ok, ClientKeys} = tmux_version:parse(<<"tmux 3.4">>),
    {ok, Formats} = tmux_version:parse(<<"tmux 3.7c">>),
    {ok, Latest} = tmux_version:parse(<<"tmux 3.8">>),
    ?assertMatch({ok, #{minimum := <<"3.8">>}}, tmux_capability:describe(layout_json)),
    ?assertEqual({error, #{code => unsupported_capability,
        capability => layout_json, minimum => <<"3.8">>, found => <<"3.3">>,
        required => <<"3.8">>, hint => <<"Use a tmux daemon at or above the required release.">>}},
        tmux_capability:require(Floor, layout_json)),
    ?assertEqual(ok, tmux_capability:require(Latest, layout_json)),
    ?assertEqual(ok, tmux_capability:require(Floor, native_list_filter)),
    ?assertMatch({error, #{code := unsupported_capability, found := <<"3.3">>,
                           required := <<"3.3a">>, hint := _}},
        tmux_capability:require(Floor, control_stream)),
    ?assertMatch({error, #{code := unsupported_capability}},
        tmux_capability:require(Floor, send_client_keys)),
    ?assertEqual(ok, tmux_capability:require(ClientKeys, send_client_keys)),
    ?assertEqual(ok, tmux_capability:require(Formats, key_list_format)),
    ?assertMatch({error, #{code := unknown_capability}},
        tmux_capability:describe(unknown)),
    ?assertMatch({error, #{code := invalid_version}},
        tmux_capability:require(invalid, layout_json)),
    lists:foreach(fun(Invalid) ->
        ?assertMatch({error, #{code := invalid_version}},
            tmux_capability:decision(Invalid, layout_json))
    end, [Latest#{candidate => -1}, Latest#{candidate => invalid},
          Latest#{candidate => 1, tracking => true},
          Latest#{candidate => 1, patch => <<"a">>},
          Latest#{tracking => true, patch => <<"a">>}]).
