-module(tmux_query_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

lazy_plan_and_validation_test() ->
    Query = tmux_query:where(#{width => #{gte => 120}}, tmux_query:panes(unopened)),
    ?assertMatch(#{pushdown := false, commands := #{candidate := []},
        candidate := #{format := <<"1">>, local_only := [#{reason := disabled}]}},
        tmux_query:explain(Query)),
    ?assertMatch(#{entity := pane,
        candidate := #{format := <<"#{e|>=|:#{pane_width},120}">>, exact := true},
        ordering := numeric_id, consistency := observed},
        tmux_query:explain(tmux_query:pushdown(true, Query))),
    ?assertMatch(#{candidate := #{format := <<"1">>}},
        tmux_query:explain(tmux_query:pushdown(false, Query))),
    ?assertError({bad_filter, #{code := unsupported_operator, path := [active, contains],
        allowed := _}}, tmux_query:where(#{active => #{contains => <<"yes">>}}, Query)),
    ?assertError({bad_query_limit, -1}, tmux_query:limit(-1, Query)).

conservative_boolean_translation_test() ->
    Base = tmux_query:pushdown(true, tmux_query:panes(unopened)),
    Native = #{active => true},
    Local = #{title => #{contains => <<"#{pid},};\n%end">>}},
    Cases = [
        {Local, <<"1">>, false},
        {#{'not' => Local}, <<"1">>, false},
        {#{'not' => Native}, <<"#{==:#{==:#{pane_active},1},0}">>, true},
        {#{'or' => [#{'and' => [Native, Local]},
                    #{'and' => [#{width => #{gte => 120}}, Local]}]},
         <<"#{||:#{==:#{pane_active},1},#{e|>=|:#{pane_width},120}}">>, false},
        {#{'and' => []}, <<"1">>, true},
        {#{'or' => []}, <<"0">>, true},
        {#{pid => #{gt => 1}}, <<"1">>, false}
    ],
    lists:foreach(fun({Criteria, Format, Exact}) ->
        #{candidate := Candidate} = tmux_query:explain(tmux_query:where(Criteria, Base)),
        ?assertEqual(Format, maps:get(format, Candidate)),
        ?assertEqual(Exact, maps:get(exact, Candidate))
    end, Cases).

composed_filters_and_post_filter_limit_test() ->
    {ok, Filter} = tmux_filter:new(window, #{name => <<"literal,#{pid}">>}),
    Query = tmux_query:limit(2, tmux_query:where(#{pane_count => #{gte => 2}},
        tmux_query:where(Filter, tmux_query:pushdown(true, tmux_query:windows(unopened))))),
    #{residual := Wire, required := Required, limit := 2,
      candidate := #{format := <<"#{e|>=|:#{window_panes},2}">>, exact := false}} =
        tmux_query:explain(Query),
    ?assertMatch({ok, _}, tmux_filter:from_wire(window, Wire)),
    ?assert(lists:member({field, window, name}, Required)),
    ?assert(lists:member({field, window, pane_count}, Required)),
    ?assertMatch({error, #{code := invalid_query_options}}, tmux_query:fetch(Query, #{retry => 2})).

chained_filters_match_flat_accounting_test() ->
    Base = tmux_query:panes(unopened),
    Conditions = [#{width => #{gte => N}} || N <- lists:seq(1, 64)],
    {ok, Flat} = tmux_filter:new(pane, #{'and' => Conditions}),
    Chained = lists:foldl(fun tmux_query:where/2, Base, Conditions),
    #{residual := Wire} = tmux_query:explain(Chained),
    ?assertEqual(tmux_filter:to_wire(Flat), Wire),
    {ok, RoundTrip} = tmux_filter:from_wire(pane, Wire),
    {ok, Match} = tmux_model:pane(#{id => <<"%1">>, width => 64}),
    {ok, Miss} = tmux_model:pane(#{id => <<"%2">>, width => 63}),
    Rows = tmux_select:from_list(pane, [Match, Miss]),
    ?assertEqual([Match], tmux_select:to_list(tmux_select:where(RoundTrip, Rows))),
    %% Canonical accounting admits 511 scalar leaves plus their conjunction,
    %% but the next leaf exceeds 1024 expression/operand nodes in both paths.
    Leaf = #{width => 64},
    Left = tmux_query:where(#{'and' => lists:duplicate(255, Leaf)}, Base),
    Boundary = tmux_query:where(#{'and' => lists:duplicate(256, Leaf)}, Left),
    {ok, FlatBoundary} = tmux_filter:new(pane, #{'and' => lists:duplicate(511, Leaf)}),
    ?assertEqual(tmux_filter:to_wire(FlatBoundary),
                 maps:get(residual, tmux_query:explain(Boundary))),
    ?assertError({bad_filter, #{code := expression_limit, path := _}},
                 tmux_query:where(Leaf, Boundary)),
    ?assertMatch({error, #{code := expression_limit}},
                 tmux_filter:new(pane, #{'and' => lists:duplicate(512, Leaf)})).
