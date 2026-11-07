-module(tmux_snapshot_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

membership_and_order_test() ->
    S2 = row(session, #{id => <<"$2">>}),
    S10 = row(session, #{id => <<"$10">>}),
    W2 = row(window, #{id => <<"@2">>, pane_count => 2}),
    W10 = row(window, #{id => <<"@10">>, pane_count => 0}),
    P2 = row(pane, #{id => <<"%2">>, window_id => <<"@2">>, index => 10}),
    P10 = row(pane, #{id => <<"%10">>, window_id => <<"@2">>, index => 2}),
    L2 = link(<<"$2">>, <<"@2">>, 2),
    L10 = link(<<"$2">>, <<"@2">>, 10),
    {ok, Snapshot} = tmux_snapshot:build(#{session => [S10, S2],
        window => [W10, W2, W2], pane => [P10, P2, P10],
        window_link => [L10, link(<<"$10">>, <<"@10">>, 0), L2]}, meta(complete)),
    ?assertEqual([<<"$2">>, <<"$10">>], ids(tmux_snapshot:sessions(Snapshot))),
    ?assertEqual([<<"@2">>, <<"@10">>], ids(tmux_snapshot:windows(Snapshot))),
    ?assertEqual([<<"%2">>, <<"%10">>], ids(tmux_snapshot:panes(Snapshot))),
    [Session | _] = tmux_snapshot:sessions(Snapshot),
    {ok, Memberships} = tmux_snapshot:related(window_links, Session, Snapshot),
    ?assertEqual([2, 10], [tmux_model:get(index, L) || L <- Memberships]),
    {ok, [Window]} = tmux_snapshot:related(windows, Session, Snapshot),
    {ok, Panes} = tmux_snapshot:related(panes, Window, Snapshot),
    ?assertEqual([<<"%10">>, <<"%2">>], ids(Panes)),
    ?assertMatch({error, #{code := snapshot_row_mismatch}},
                 tmux_snapshot:related(windows, S2, Snapshot)),
    [Pane | _] = Panes,
    ?assertEqual({ok, Window}, tmux_snapshot:related(window, Pane, Snapshot)).

conflicts_and_dangling_edges_test() ->
    W1 = row(window, #{id => <<"@1">>, name => <<"first">>}),
    W2 = row(window, #{id => <<"@1">>, name => <<"second">>}),
    ?assertMatch({error, #{code := inconsistent_capture, reason := conflicting_observations}},
        tmux_snapshot:build(#{window => [W1, W2]}, meta(partial))),
    Empty = #{session => [], window => [], pane => [], window_link => []},
    ?assertMatch({error, #{code := inconsistent_capture, reason := missing_parent}},
        tmux_snapshot:build(Empty#{window_link => [link(<<"$0">>, <<"@1">>, 0)]}, meta(complete))),
    Session = row(session, #{id => <<"$0">>}),
    Other = row(window, #{id => <<"@2">>}),
    ?assertMatch({error, #{code := inconsistent_capture, reason := conflicting_positions}},
        tmux_snapshot:build(Empty#{session => [Session], window => [W1, Other],
            window_link => [link(<<"$0">>, <<"@1">>, 0), link(<<"$0">>, <<"@2">>, 0)]}, meta(complete))),
    Counted = row(window, #{id => <<"@1">>, pane_count => 1}),
    ?assertMatch({error, #{code := inconsistent_capture, reason := pane_count}},
        tmux_snapshot:build(Empty#{window => [Counted]}, meta(complete))).

coverage_before_traversal_test() ->
    {ok, Empty} = tmux_snapshot:build(#{pane => []}, meta(partial)),
    ?assertMatch({error, #{code := incomplete_snapshot}},
        tmux_snapshot:require([{relation, pane, window}], Empty)),
    ?assertMatch({error, #{code := incomplete_snapshot}},
        tmux_snapshot:require([{field, pane, width}], Empty)),
    Pane = row(pane, #{id => <<"%1">>, pid => none, title => unavailable}),
    {ok, Partial} = tmux_snapshot:build(#{pane => [Pane]}, meta(partial)),
    ?assertEqual(ok, tmux_snapshot:require([{field, pane, pid}], Partial)),
    ?assertMatch({error, #{requirements := [#{state := unavailable}]}},
        tmux_snapshot:require([{field, pane, title}], Partial)),
    ?assertMatch({error, #{requirements := [#{state := not_loaded}]}},
        tmux_snapshot:require([{field, pane, width}], Partial)),
    ?assertMatch({error, #{code := invalid_requirement}},
        tmux_snapshot:require([{field, pane, nonexistent}], Partial)),
    ?assertError({incomplete_snapshot, _}, tmux_snapshot:sessions(Partial)).

meta(Mode) -> #{origin => make_ref(), id => make_ref(), generation => make_ref(), graph => Mode}.
row(Entity, Fields) -> {ok, Row} = tmux_model:new(Entity, Fields), Row.
link(Session, Window, Index) -> row(window_link,
    #{session_id => Session, window_id => Window, index => Index}).
ids(Rows) -> [tmux_model:get(id, Row) || Row <- Rows].
