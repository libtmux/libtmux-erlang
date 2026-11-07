-module(tmux_regex_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

portable_filter_round_trip_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%1">>, title => <<"api-17">>}),
    Criteria = #{title => #{regex => #{pattern => <<"^api-[0-9]{1,3}$">>,
                                       dialect => portable_v1, flags => []}}},
    {ok, Filter} = tmux_filter:new(pane, Criteria),
    {ok, Document} = tmux_json:decode(iolist_to_binary(json:encode(tmux_filter:to_wire(Filter)))),
    ?assertEqual({ok, Filter}, tmux_filter:from_wire(pane, Document)),
    Selection = tmux_select:from_list(pane, [Pane]),
    ?assertEqual({ok, Pane}, tmux_select:one(Filter, Selection)).

validation_before_empty_selection_test() ->
    Empty = tmux_select:from_list(pane, []),
    lists:foreach(fun({Regex, Code, Path}) ->
        ?assertMatch({error, #{code := Code, path := Path}},
            tmux_select:try_where(#{title => #{regex => Regex}}, Empty))
    end, [{#{pattern => <<"a">>, dialect => portable_v2}, unsupported_dialect,
            [title, regex, dialect]},
          {#{pattern => <<"a">>, dialect => portable_v1, flags => [caseless]},
            unsupported_regex_flags, [title, regex, flags]},
          {#{pattern => <<"a">>, dialect => portable_v1, extra => true},
            unknown_field, [title, regex, extra]},
          {#{pattern => <<"a+">>, dialect => portable_v1}, unsupported_regex_syntax,
            [title, regex, pattern]},
          {#{dialect => portable_v1}, required_field, [title, regex, pattern]}]).

evaluation_failure_contract_test() ->
    Pattern = <<"^(a|aa){1,64}$">>,
    Criteria = #{title => #{regex => #{pattern => Pattern, dialect => portable_v1}}},
    lists:foreach(fun({Title, Code}) ->
        {ok, Pane} = tmux_model:pane(#{id => <<"%1">>, title => Title}),
        Selection = tmux_select:from_list(pane, [Pane]),
        ?assertMatch({error, #{code := Code, field := <<"tmux.pane.title">>}},
            tmux_select:try_where(Criteria, Selection)),
        ?assertError({filter_evaluation_failed, #{code := Code, field := <<"tmux.pane.title">>}},
            tmux_select:where(Criteria, Selection)),
        ?assertError({filter_evaluation_failed, #{code := Code, field := <<"tmux.pane.title">>}},
            tmux_select:one(Criteria, Selection)),
        {ok, Snapshot} = tmux_snapshot:build(#{pane => [Pane]},
            #{origin => make_ref(), id => make_ref(), generation => make_ref(), graph => partial}),
        [Captured] = tmux_snapshot:panes(Snapshot),
        {ok, Filter} = tmux_filter:new(pane, Criteria),
        {ok, Prepared} = tmux_filter:prepare(Filter, Snapshot),
        Predicate = tmux_filter:predicate(Prepared),
        ?assertError({filter_evaluation_failed, #{code := Code, field := <<"tmux.pane.title">>}},
            Predicate(Captured))
    end, [{<<(binary:copy(<<"a">>,64))/binary,"!">>, regex_resource_limit},
          {<<195,169>>, unsupported_regex_subject},
          {binary:copy(<<"a">>,1048577), regex_subject_limit}]).

grammar_and_anchors_test() ->
    lists:foreach(fun(Pattern) ->
        ?assertMatch({error, _}, tmux_regex:validate(Pattern))
    end, [<<"a*">>, <<"a+">>, <<"a?">>, <<"a{1,}">>, <<"a{65}">>,
          <<"a{2,1}">>, <<"(?=a)">>, <<"(?:a)">>, <<"(a)\\1">>, <<"\\d">>,
          <<"[[:alpha:]]">>, <<"[z-a]">>, <<"[">>, <<"(">>, <<"a)">>,
          <<"a{1}{2}">>, <<"^{0}">>, <<195,169>>]),
    {ok, Exact} = tmux_regex:compile(<<"^a$">>),
    ?assertEqual({ok, true}, tmux_regex:run(Exact, <<"a">>)),
    ?assertEqual({ok, false}, tmux_regex:run(Exact, <<"a\n">>)),
    {ok, Dot} = tmux_regex:compile(<<"^.$">>),
    ?assertEqual({ok, true}, tmux_regex:run(Dot, <<13>>)),
    ?assertEqual({ok, false}, tmux_regex:run(Dot, <<10>>)),
    ?assertMatch({error, #{code := unsupported_regex_subject}}, tmux_regex:run(Dot, <<195,169>>)),
    {ok, Symbols} = tmux_regex:compile(<<"^\\*\\+\\?$">>),
    ?assertEqual({ok, true}, tmux_regex:run(Symbols, <<"*+?">>)).

resource_failure_is_not_a_nonmatch_test() ->
    {ok, Expensive} = tmux_regex:compile(<<"^(a|aa){1,64}$">>),
    ?assertMatch({error, #{code := regex_resource_limit}},
        tmux_regex:run(Expensive, <<(binary:copy(<<"a">>,64))/binary,"!">>)),
    ?assertMatch({error, #{code := regex_complexity_limit}},
        tmux_regex:validate(<<"((a{64}){64}){64}">>)),
    ?assertMatch({error, #{code := pattern_limit}},
        tmux_regex:validate(binary:copy(<<"a">>, 1025))).
