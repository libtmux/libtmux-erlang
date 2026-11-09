-module(tmux_option_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

batch_validation_before_dispatch_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%1">>}),
    lists:foreach(fun({Scopes, Name}) ->
        ?assertMatch({error, #{code := unsupported_capability}},
            tmux_option:get_many(Scopes, Name, #{}))
    end, [{[], <<"@value">>}, {lists:duplicate(8, Pane), <<"@value">>},
        {[Pane | invalid], <<"@value">>}, {[Pane], <<"@unsafe\nkey">>},
        {[{session_defaults, invalid}], <<"@value">>},
        {[Pane], {<<"@value">>, 0}}, {[Pane], <<"update-environment">>},
        {[Pane], <<"default-client-command">>}, {[Pane], <<"pane-died">>}]),
    ?assertMatch({error, #{code := detached_reference}},
        tmux_option:get_many([Pane], <<"@value">>, #{})),
    ?assertMatch({error, #{code := unknown_option}},
        tmux_option:get_many([Pane], <<"@value">>, #{quiet => true})).

batch_wire_framing_test() ->
    {ok, Version} = tmux_version:parse(<<"tmux 3.8">>),
    Rows = [#{id => <<"%1">>, metadata => #{type => string, array => false}}],
    Begin = <<"__ltm_option_begin_1:%1\n">>,
    End = <<"__ltm_option_end_1:%1\n">>,
    ?assertEqual({ok, [none]}, tmux_option_batch:decode(<<"@v">>,
        <<Begin/binary, End/binary>>, Rows, Version)),
    ?assertEqual({ok, [<<>>]}, tmux_option_batch:decode(<<"@v">>,
        <<Begin/binary, "@v ''\n", End/binary>>, Rows, Version)),
    Forged = <<"__ltm_option_end_1:%1">>,
    ?assertEqual({ok, [<<"line\n", Forged/binary>>]}, tmux_option_batch:decode(
        <<"@v">>, <<Begin/binary, "@v \"line\\n", Forged/binary, "\"\n",
                    End/binary>>, Rows, Version)),
    lists:foreach(fun(Output) ->
        ?assertMatch({error, #{code := invalid_observation}},
            tmux_option_batch:decode(<<"@v">>, Output, Rows, Version))
    end, [<<Begin/binary>>, <<Begin/binary, "@other x\n", End/binary>>,
        <<Begin/binary, "@v a\n@v b\n", End/binary>>,
        <<Begin/binary, End/binary, "hook-output\n">>,
        <<Begin/binary, "__ltm_option_end_2:%1\n">>]),
    ?assertMatch({error, #{code := target_gone}}, tmux_option_batch:decode(
        <<"@v">>, <<Begin/binary, "__ltm_option_end_1:\n">>, Rows, Version)),
    {ok, V34} = tmux_version:parse(<<"tmux 3.4">>),
    OldValue = <<"@v \"line\\r\\\\r\\377", $\\, $\\, $$, "HOME\"\n">>,
    ?assertEqual({ok, [<<"line", 13, $\\, $r, 255, "$HOME">>]},
        tmux_option_batch:decode(<<"@v">>,
            <<Begin/binary, OldValue/binary, End/binary>>, Rows, V34)).

batch_unexpected_lines_heap_bound_test() ->
    {ok, Version} = tmux_version:parse(<<"tmux 3.8">>),
    Rows = [#{id => <<"%1">>, metadata => #{type => string, array => false}}],
    Output = binary:copy(<<$\n>>, 1048576),
    Parent = self(), Ref = make_ref(),
    {Pid, Monitor} = spawn_opt(fun() ->
        Parent ! {Ref, tmux_option_batch:decode(<<"@v">>, Output, Rows, Version)}
    end, [monitor, {max_heap_size, #{size => 262144, kill => true, error_logger => false}}]),
    try
        receive
            {Ref, Result} -> ?assertMatch({error, #{code := invalid_observation}}, Result);
            {'DOWN', Monitor, process, Pid, Reason} -> ?assertEqual(normal, Reason)
        after 900 -> ?assert(false) end,
        receive {'DOWN', Monitor, process, Pid, normal} -> ok
        after 900 -> ?assert(false) end
    after exit(Pid, kill), erlang:demonitor(Monitor, [flush]) end.

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
    ?assertMatch({error, #{code := invalid_option_key}},
        tmux_option:get({session_defaults, invalid},
            {{<<"update-environment">>, 1}, 2}, #{})),
    ?assertMatch({error, #{code := invalid_option_value}},
        tmux_option:set(Pane, <<"@value">>, <<0>>)),
    ?assertMatch({error, #{code := unknown_option}},
        tmux_option:get(Pane, <<"@value">>, #{quiet => true})).

catalogue_version_boundary_test() ->
    lists:foreach(fun(Release) ->
        {ok, Version} = tmux_version:require(<<"tmux ", Release/binary>>),
        ?assertMatch({ok, #{scopes := [server], array := false}},
            tmux_option:describe(Version, <<"exit-empty">>))
    end, [<<"3.3a">>, <<"3.4">>, <<"3.5">>, <<"3.5a">>, <<"3.6">>,
          <<"3.6a">>, <<"3.6b">>, <<"3.7">>, <<"3.7a">>, <<"3.7b">>,
          <<"3.7c">>, <<"3.8">>]),
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

scalar_quoted_codec_test() ->
    {ok, V34} = tmux_version:parse(<<"tmux 3.4">>),
    {ok, V35} = tmux_version:parse(<<"tmux 3.5a">>),
    Meta = #{array => false, type => string},
    Expected = <<"line", 13, $\\, $r, 255, "$HOME">>,
    Old = <<"@value \"line\\r\\\\r\\377", $\\, $\\, $$, "HOME\"\n">>,
    New = <<"@value \"line\\r\\\\r\\377", $\\, $$, "HOME\"\n">>,
    ?assertEqual({ok, Expected}, tmux_option_codec:decode(<<"@value">>, Old, Meta, V34)),
    ?assertEqual({ok, Expected}, tmux_option_codec:decode(<<"@value">>, New, Meta, V35)),
    Name = <<"@caf", 195, 169, 13, 255>>,
    Header = <<"@caf", 195, 169, "\\r\\377* ''\n">>,
    ?assertEqual({ok, <<>>}, tmux_option_codec:decode(Name, Header, Meta, V35)),
    Extended = <<$@, 244, 144, 128, 128>>,
    ?assertEqual({ok, <<"x">>}, tmux_option_codec:decode(Extended,
        <<Extended/binary, " x\n">>, Meta, V35)),
    ?assertEqual({ok, <<"display-message \"\\\\r\"">>},
        tmux_option_codec:decode(<<"default-client-command">>,
            <<"default-client-command display-message \"\\\\r\"\n">>,
            #{array => false, type => command}, V35)).

command_array_codec_test() ->
    {ok, Version} = tmux_version:parse(<<"tmux 3.3">>),
    Name = <<"pane-died">>,
    Command = <<"set-option -g @value \"line\\n\\\\n\\$HOME\"">>,
    Output = <<Name/binary, "[7] ", Command/binary, "\n">>,
    ?assertEqual({ok, #{7 => Command}}, tmux_option_codec:decode(Name,
        Output, #{array => true, type => command}, Version)).
