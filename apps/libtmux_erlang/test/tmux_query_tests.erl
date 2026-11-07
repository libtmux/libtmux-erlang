-module(tmux_query_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

lazy_plan_and_validation_test() ->
    Query = tmux_query:where(#{width => #{gte => 120}}, tmux_query:panes(unopened)),
    ?assertMatch(#{entity := pane,
        candidate := #{format := <<"#{e|>=|:#{pane_width},120}">>, exact := true},
        ordering := numeric_id, consistency := observed}, tmux_query:explain(Query)),
    ?assertMatch(#{candidate := #{format := <<"1">>}},
        tmux_query:explain(tmux_query:pushdown(false, Query))),
    ?assertError({bad_filter, #{code := unsupported_operator, path := [active, contains],
        allowed := _}}, tmux_query:where(#{active => #{contains => <<"yes">>}}, Query)),
    ?assertError({bad_query_limit, -1}, tmux_query:limit(-1, Query)).

conservative_boolean_translation_test() ->
    Base = tmux_query:panes(unopened),
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
        tmux_query:where(Filter, tmux_query:windows(unopened)))),
    #{residual := Wire, required := Required, limit := 2,
      candidate := #{format := <<"#{e|>=|:#{window_panes},2}">>, exact := false}} =
        tmux_query:explain(Query),
    ?assertMatch({ok, _}, tmux_filter:from_wire(window, Wire)),
    ?assert(lists:member({field, window, name}, Required)),
    ?assert(lists:member({field, window, pane_count}, Required)),
    ?assertMatch({error, #{code := invalid_query_options}}, tmux_query:fetch(Query, #{retry => 2})).
