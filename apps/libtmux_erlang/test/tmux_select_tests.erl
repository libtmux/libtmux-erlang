-module(tmux_select_tests).
-behaviour(tmux_matcher).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").
-export([prepare/2]).

list_order_and_cardinality_test() ->
    A = row(pane, #{id => <<"%2">>, width => 80, active => false}),
    B = row(pane, #{id => <<"%1">>, width => 120, active => true}),
    Bound = tmux_model:bind(B, make_ref(), make_ref()),
    Rows = [A, Bound, A],
    S = tmux_select:from_list(pane, Rows),
    ?assertEqual(Rows, tmux_select:to_list(S)),
    ?assertEqual([A, A], tmux_select:to_list(tmux_select:where(#{active => false}, S))),
    ?assertEqual({ok, Bound}, tmux_select:one(#{width => #{gte => 100}}, S)),
    ?assertEqual({ok, A}, tmux_select:first(S)),
    ?assertEqual({error, {multiple_matches, #{at_least => 2}}}, tmux_select:one(#{width => 80}, S)),
    ?assertEqual(3, tmux_select:count(#{width => #{in => [80, 120]}}, S)),
    ?assertEqual(2, tmux_select:fold(fun(_, Acc) -> Acc + 1 end, 0, tmux_select:take(2, S))),
    ?assertEqual([A, Bound], tmux_select:to_list(tmux_select:take(2, S))),
    Empty = tmux_select:where(#{width => 1}, S),
    ?assertEqual(none, tmux_select:first(Empty)),
    ?assertEqual({error, no_match}, tmux_select:one(Empty)),
    ?assertEqual({ok, none}, tmux_select:one_or_none(Empty)),
    ?assertError(no_match, tmux_select:one_or_error(Empty)),
    ?assertNot(tmux_select:exists(Empty)),
    ?assert(tmux_select:exists(#{active => true}, S)),
    ?assertEqual(Bound, tmux_select:one_or_error(#{active => true}, S)),
    ?assertMatch(#{size := 3, snapshot_id := none,
                  coverage := #{relations := #{window := not_loaded}}}, tmux_select:summary(S)),
    ?assertError({bad_selection, #{code := wrong_row_entity, path := [0]}},
        tmux_select:from_list(window, [A])).

coverage_before_short_circuit_test() ->
    Empty = tmux_select:from_list(pane, []),
    ?assertError({bad_filter, _}, tmux_select:where(#{active => #{contains => <<"yes">>}}, Empty)),
    ?assertError({incomplete_snapshot, _}, tmux_select:exists(#{active => true}, Empty)),
    ?assertError({incomplete_snapshot, _}, tmux_select:one(#{window => #{is => #{}}}, Empty)),
    ?assertEqual(0, tmux_select:size(tmux_select:where(#{}, Empty))),
    S = tmux_select:from_list(pane, [row(pane, #{id => <<"%1">>, active => true}),
                                   row(pane, #{id => <<"%2">>})]),
    Short = tmux_select:take(1, S),
    ?assertError({incomplete_snapshot, _}, tmux_select:first(#{active => true}, Short)),
    ?assertMatch({error, #{code := incomplete_snapshot}},
        tmux_select:try_where(#{'or' => [#{}, #{active => true}]}, S)),
    ?assertMatch({error, #{code := unknown_field}},
        tmux_select:try_where(#{'and' => [#{'or' => []}, #{not_a_field => true}]}, Empty)).

callbacks_and_matcher_test() ->
    S = tmux_select:from_list(pane, [row(pane, #{id => <<"%1">>})]),
    ?assertError(callback_broke, tmux_select:filter(fun(_) -> error(callback_broke) end, S)),
    ?assertError({bad_filter, yes}, tmux_select:filter(fun(_) -> yes end, S)),
    Snapshot = snapshot(),
    Windows = tmux_select:windows(Snapshot),
    {ok, Matches} = tmux_select:matching({?MODULE, {self(), ok}}, Windows),
    ?assertEqual(3, tmux_select:size(Matches)),
    ?assertEqual(prepared_once, receive Message -> Message after 0 -> missing end),
    ?assertEqual(none, receive _ -> unexpected after 0 -> none end),
    ?assertEqual({error, requested}, tmux_select:matching({?MODULE, {self(), fail}}, Windows)),
    ?assertEqual({error, #{code => matcher_requires_snapshot}},
        tmux_select:matching({?MODULE, {self(), ok}}, S)).

prepare(Owner, _) when is_pid(Owner) -> {error, unused};
prepare({Owner, ok}, _) -> Owner ! prepared_once, {ok, fun(_) -> true end};
prepare({_, fail}, _) -> {error, requested}.

correlation_quantifiers_and_membership_test() ->
    Snapshot = snapshot(),
    Windows = tmux_select:windows(Snapshot),
    Correlated = #{panes => #{some => #{active => true, current_command => <<"vim">>}}},
    Independent = #{'and' => [#{panes => #{some => #{active => true}}},
                              #{panes => #{some => #{current_command => <<"vim">>}}}]},
    ?assertEqual([<<"@2">>], ids(tmux_select:where(Correlated, Windows))),
    ?assertEqual([<<"@1">>, <<"@2">>], ids(tmux_select:where(Independent, Windows))),
    ?assertEqual([<<"@3">>], ids(tmux_select:where(#{panes => #{none => #{}}}, Windows))),
    ?assertEqual([<<"@2">>, <<"@3">>], ids(tmux_select:where(#{panes => #{every => #{active => true}}}, Windows))),
    ?assertEqual([<<"@1">>], ids(tmux_select:where(#{panes => #{count => #{gte => 2}}}, Windows))),
    Sessions = tmux_select:sessions(Snapshot),
    ?assertEqual(1, tmux_select:count(#{windows => #{count => 3}, window_links => #{count => 4}}, Sessions)),
    ?assertEqual([<<"%1">>, <<"%2">>], ids(tmux_select:where(
        #{window => #{is_not => #{name => <<"both">>}}}, tmux_select:panes(Snapshot)))),
    %% A copied list keeps row origins but cannot infer graph completeness.
    DetachedGraph = tmux_select:from_list(window, tmux_select:to_list(Windows)),
    ?assertError({incomplete_snapshot, _}, tmux_select:where(Correlated, DetachedGraph)).

snapshot() ->
    {ok, Snapshot} = tmux_snapshot:build(#{
        session => [row(session, #{id => <<"$1">>})],
        window => [row(window, #{id => <<"@1">>, name => <<"separate">>}),
                   row(window, #{id => <<"@2">>, name => <<"both">>}),
                   row(window, #{id => <<"@3">>, name => <<"empty">>})],
        window_link => [membership(1, 0), membership(1, 3), membership(2, 1), membership(3, 2)],
        pane => [pane(1, 1, 0, true, <<"cat">>), pane(2, 1, 1, false, <<"vim">>),
                 pane(3, 2, 0, true, <<"vim">>)]},
        #{origin => make_ref(), id => make_ref(), generation => make_ref(), graph => complete}),
    Snapshot.
row(Entity, Fields) -> {ok, Row} = tmux_model:new(Entity, Fields), Row.
pane(Id, Window, Index, Active, Command) -> row(pane,
    #{id => <<"%", (integer_to_binary(Id))/binary>>, window_id => <<"@", (integer_to_binary(Window))/binary>>,
      index => Index, active => Active, current_command => Command}).
membership(Window, Index) -> row(window_link, #{session_id => <<"$1">>, index => Index,
                                        window_id => <<"@", (integer_to_binary(Window))/binary>>}).
ids(Selection) -> [tmux_model:get(id, Row) || Row <- tmux_select:to_list(Selection)].
