-module(tmux_filter_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

normalization_and_wire_test() ->
    Cases = [#{}, #{'and' => []}, #{'or' => []}, #{'not' => #{active => true}},
        #{width => #{gte => 80.0, lt => 140}, pid => #{present => false}},
        #{current_command => #{in => [<<"nvim">>, <<"vim">>, <<"vim">>]}},
        #{current_path => <<0, 255>>, exit_status => #{in => [none, 0, 2]}},
        #{window => #{is_not => #{panes => #{count => #{gte => 2}}}}}],
    lists:foreach(fun(Criteria) ->
        {ok, Filter} = tmux_filter:new(pane, Criteria),
        ?assertEqual({ok, Filter}, tmux_filter:new(pane, Filter)),
        Wire = tmux_filter:to_wire(Filter),
        {ok, Document} = tmux_filter:decode_json(iolist_to_binary(json:encode(Wire))),
        ?assertEqual({ok, Filter}, tmux_filter:from_wire(pane, Document))
    end, Cases),
    {ok, Integer} = tmux_filter:new(pane, #{width => 120}),
    ?assertEqual({ok, Integer}, tmux_filter:new(pane, #{width => 120.0})),
    ?assertMatch({error, #{code := wrong_filter_entity}}, tmux_filter:new(window, Integer)).

validation_paths_and_bounds_test() ->
    ?assertMatch({error, #{code := unsupported_operator, path := [active, contains]}},
        tmux_filter:new(pane, #{active => #{contains => <<"yes">>}})),
    lists:foreach(fun(Value) ->
        ?assertMatch({error, #{code := invalid_value}}, tmux_filter:new(pane, #{width => Value}))
    end, [none, <<"80">>, -1, 1.5, 9007199254740992, 9007199254740992.0]),
    ?assertMatch({error, #{code := invalid_value}}, tmux_filter:new(pane, #{pid => 0})),
    ?assertMatch({error, #{code := invalid_value}}, tmux_filter:new(pane, #{title => <<255>>})),
    ?assertMatch({error, #{code := unsupported_dialect}}, tmux_filter:new(pane,
        #{title => #{regex => #{pattern => <<"a">>, dialect => portable_v1}}})),
    ?assertMatch({error, #{code := membership_limit}}, tmux_filter:new(pane,
        #{width => #{in => lists:seq(0, 256)}})),
    ?assertMatch({error, #{code := expression_limit}}, tmux_filter:new(pane,
        #{'or' => lists:duplicate(1024, #{})})),
    Deep = lists:foldl(fun(_, C) -> #{'not' => C} end, #{}, lists:seq(1, 32)),
    ?assertMatch({error, #{code := depth_limit}}, tmux_filter:new(pane, Deep)),
    ?assertMatch({error, #{code := expected_array}}, tmux_filter:new(pane, #{'or' => [#{} | broken]})),
    ?assertMatch({error, #{code := expected_object}}, tmux_filter:new(pane, [{active, true}])),
    Wire = #{<<"version">> => 1, <<"entity">> => <<"window">>,
        <<"where">> => #{<<"panes">> => #{<<"some">> => #{<<"active">> => #{<<"contains">> => <<"x">>}}}}},
    ?assertMatch({error, #{path := [<<"where">>, <<"panes">>, <<"some">>, <<"active">>, <<"contains">>]}},
        tmux_filter:from_wire(window, Wire)).

prepared_context_and_nullable_test() ->
    Pane = row(pane, #{id => <<"%1">>, width => 80, title => <<"caf",195,169>>, pid => none}),
    {ok, S1} = tmux_snapshot:build(#{pane => [Pane]}, meta(partial)),
    {ok, S2} = tmux_snapshot:build(#{pane => [Pane]}, meta(partial)),
    [P1] = tmux_snapshot:panes(S1),
    [P2] = tmux_snapshot:panes(S2),
    {ok, F} = tmux_filter:new(pane, #{width => #{gte => 80}, title => #{ends_with => <<195,169>>},
                                    pid => #{present => false}}),
    {ok, Prepared} = tmux_filter:prepare(F, S1),
    Predicate = tmux_filter:predicate(Prepared),
    ?assert(Predicate(P1)),
    ?assertMatch({error, #{code := prepared_context_mismatch}}, tmux_filter:matches(Prepared, P2)),
    ?assertMatch({error, #{code := prepared_context_mismatch}}, tmux_filter:matches(Prepared, Pane)),
    lists:foreach(fun({Criteria, Expected}) ->
        {ok, Filter} = tmux_filter:new(pane, Criteria),
        {ok, P} = tmux_filter:prepare(Filter, S1),
        ?assertEqual({ok, Expected}, tmux_filter:matches(P, P1))
    end, [{#{pid => none}, true}, {#{pid => #{gt => 1}}, false},
          {#{'not' => #{pid => #{gt => 1}}}, true}, {#{title => #{contains => <<>>}}, true},
          {#{width => #{not_in => [81, 82]}}, true}]).

canonical_wire_limits_test() ->
    %% Normalization splits several scalar operators into conjunctive leaves.
    %% The resulting portable document must still fit the decoder's limits.
    Wide = #{'or' => lists:duplicate(300, #{width => #{gte => 80, lte => 120}})},
    ?assertMatch({error, #{code := expression_limit}}, tmux_filter:new(pane, Wide)),
    Deep = lists:foldl(fun(_, C) -> #{'not' => C} end, #{width => 1}, lists:seq(1, 30)),
    ?assertMatch({error, #{code := depth_limit}}, tmux_filter:new(pane, Deep)),
    ?assertMatch({error, #{code := document_limit}},
        tmux_filter:new(pane, #{title => binary:copy(<<"a">>, 262144)})).

meta(Mode) -> #{origin => make_ref(), id => make_ref(), generation => make_ref(), graph => Mode}.
row(Entity, Fields) -> {ok, Row} = tmux_model:new(Entity, Fields), Row.
