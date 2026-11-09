-module(tmux_workspace_plan_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

canonical_wire_test() ->
    A = #{<<"b">> => [true, null, <<"text">>], <<"a">> => #{<<"z">> => 2}},
    B = maps:from_list(lists:reverse(maps:to_list(A))),
    ?assertEqual(<<"{\"a\":{\"z\":2},\"b\":[true,null,\"text\"]}">>,
        tmux_workspace_wire:encode(A)),
    ?assertEqual(tmux_workspace_wire:digest(A), tmux_workspace_wire:digest(B)),
    ?assertNotEqual(tmux_workspace_wire:digest(A),
        tmux_workspace_wire:digest(A#{<<"a">> => 2})),
    ?assertThrow({workspace_error, #{code := unknown_field,
        path := [<<"policy">>, <<"socket">>]}},
        tmux_workspace_wire:fields(#{<<"socket">> => <<"ignored">>},
            [<<"endpoint">>], [<<"policy">>])).

planning_and_idempotence_test() ->
    D = desired(),
    Empty = #{<<"instance">> => instance(), <<"resources">> => [], <<"links">> => []},
    {ok, New} = tmux_workspace_plan:from_state(<<"/workspace.json">>, D, Empty, #{}),
    #{<<"steps">> := [#{<<"op">> := <<"create_session">>} | _]} =
        tmux_workspace_plan:to_map(New),
    State = managed(),
    {ok, Same} = tmux_workspace_plan:from_state(<<"/workspace.json">>, D, State, #{}),
    ?assertEqual([], maps:get(<<"steps">>, tmux_workspace_plan:to_map(Same))),
    ?assertEqual({ok, Same}, tmux_workspace_plan:from_map(
        tmux_workspace_plan:to_map(Same))),
    [S] = maps:get(sessions, D), [W] = maps:get(windows, S),
    Changed = D#{sessions => [S#{windows => [W#{panes => [
        #{key => <<"p">>, cwd => <<"/">>, launch => #{argv => [<<"/bin/true">>]}}
    ]}]}]},
    {ok, Update} = tmux_workspace_plan:from_state(
        <<"/workspace.json">>, Changed, State, #{}),
    ?assertEqual([<<"respawn">>, <<"stamp">>],
        [maps:get(<<"op">>, Step) || Step <- maps:get(<<"steps">>,
            tmux_workspace_plan:to_map(Update))]),
    Map = tmux_workspace_plan:to_map(Same),
    ?assertMatch({error, #{code := plan_hash_mismatch}},
        tmux_workspace_plan:from_map(Map#{<<"source">> => <<"/different.json">>})).

ownership_and_adoption_test() ->
    State = managed(),
    [S, W, P] = maps:get(<<"resources">>, State),
    Missing = State#{<<"resources">> => [S, W, P#{<<"tag">> => null}]},
    ?assertMatch({error, #{code := plan_conflict}},
        tmux_workspace_plan:from_state(<<"/workspace.json">>, desired(), Missing, #{})),
    Untagged = State#{<<"resources">> => [R#{<<"tag">> => null} || R <- [S, W, P]]},
    ?assertMatch({error, #{code := plan_conflict, reason := name_in_use}},
        tmux_workspace_plan:from_state(<<"/workspace.json">>, desired(), Untagged, #{})),
    {ok, Adopt} = tmux_workspace_plan:from_state(
        <<"/workspace.json">>, desired(), Untagged,
        #{adopt => [<<"s">>, <<"w">>, <<"p">>]}),
    ?assert(lists:member(<<"respawn">>, [maps:get(<<"op">>, X)
        || X <- maps:get(<<"steps">>, tmux_workspace_plan:to_map(Adopt))])).

ordered_creation_test() ->
    D = desired(), [S] = maps:get(sessions, D), [W] = maps:get(windows, S),
    [P] = maps:get(panes, W),
    Three = D#{sessions => [S#{windows => [W#{panes => [P,
        P#{key => <<"p1">>}, P#{key => <<"p2">>}]}]}]},
    Empty = #{<<"instance">> => instance(), <<"resources">> => [], <<"links">> => []},
    {ok, Plan} = tmux_workspace_plan:from_state(<<"/workspace.json">>, Three, Empty, #{}),
    Splits = [X || #{<<"op">> := <<"create_pane">>} = X <-
        maps:get(<<"steps">>, tmux_workspace_plan:to_map(Plan))],
    ?assertEqual([#{<<"key">> => <<"p">>}, #{<<"key">> => <<"p">>}],
        [maps:get(<<"anchor">>, X) || X <- Splits]),
    ?assertEqual([#{<<"op">> => <<"swap_panes">>, <<"key">> => <<"p1">>,
        <<"with">> => <<"p2">>}], [X || #{<<"op">> := <<"swap_panes">>} = X <-
            maps:get(<<"steps">>, tmux_workspace_plan:to_map(Plan))]).

exhausted_anchor_is_not_reused_test() ->
    D = desired(), [S] = maps:get(sessions, D), [W] = maps:get(windows, S),
    [P] = maps:get(panes, W),
    More = D#{sessions => [S#{windows => [W#{panes => [P |
        [P#{key => integer_to_binary(I)} || I <- lists:seq(1, 8)]]}]}]},
    State = managed(), [SR, WR, PR] = maps:get(<<"resources">>, State),
    Tiny = PR,
    Large = PR#{<<"id">> => <<"%2">>, <<"tag">> => null, <<"index">> => 1},
    Layout = layout([cell(<<"%1">>, 3, 1), cell(<<"%2">>, 40, 24)]),
    {ok, Plan} = tmux_workspace_plan:from_state(<<"/workspace.json">>, More,
        State#{<<"resources">> => [SR, WR#{<<"layout">> => Layout}, Tiny, Large]}, #{}),
    Anchors = [A || #{<<"op">> := <<"create_pane">>, <<"anchor">> := A} <-
        maps:get(<<"steps">>, tmux_workspace_plan:to_map(Plan))],
    ?assertEqual(1, length([A || #{<<"target">> := <<"pane:%1">>} = A <- Anchors])).

changed_input_cannot_dispatch_test() ->
    File = filename:join("/tmp", <<"ltm-plan-",
        (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary,
        ".json">>),
    {ok, Plan} = tmux_workspace_plan:from_state(File, desired(), managed(), #{}),
    Source = #{version => 1, id => <<"demo">>, endpoint => <<"dev">>, sessions => [
        #{key => <<"s">>, name => <<"work">>, windows => [#{key => <<"w">>,
            name => <<"api">>, panes => [#{key => <<"p">>, cwd => <<"/">>,
                argv => [<<"/bin/true">>]}]}]}]},
    ok = file:write_file(File, json:encode(Source)),
    try
        ?assertMatch({error, #{code := desired_input_changed, completed := []}},
            tmux_workspace_apply:run(Plan, unopened, #{}))
    after ok = file:delete(File) end.

rehashed_plan_cannot_skip_transitions_test() ->
    D = desired(), [S] = maps:get(sessions, D), [W] = maps:get(windows, S),
    [P] = maps:get(panes, W),
    Changed = D#{sessions => [S#{windows => [W#{layout => <<"tiled">>,
        panes => [P#{launch => #{argv => [<<"/bin/true">>]}}]}]}]},
    with_source(Changed, fun(File) ->
        {ok, Plan} = tmux_workspace_plan:from_state(File, Changed, managed(), #{}),
        Map = tmux_workspace_plan:to_map(Plan),
        lists:foreach(fun(Op) ->
            Steps = [X || X <- maps:get(<<"steps">>, Map),
                maps:get(<<"op">>, X) =/= Op],
            {ok, Forged} = tmux_workspace_plan:from_map(rehash(Map#{<<"steps">> => Steps})),
            ?assertMatch({error, #{code := invalid_plan, completed := []}},
                tmux_workspace_apply:run(Forged, unopened, #{}))
        end, [<<"respawn">>, <<"layout">>])
    end).

rehashed_adoption_cannot_rebind_test() ->
    [S, W, P] = maps:get(<<"resources">>, managed()),
    Untagged = [R#{<<"tag">> => null} || R <- [S, W, P]],
    ForeignW = W#{<<"id">> => <<"@2">>, <<"tag">> => null},
    ForeignP = P#{<<"id">> => <<"%2">>, <<"parent">> => <<"@2">>, <<"tag">> => null},
    ForeignS = S#{<<"id">> => <<"$2">>, <<"name">> => <<"other">>, <<"tag">> => null},
    State = (managed())#{<<"resources">> => Untagged ++ [ForeignS, ForeignW, ForeignP],
        <<"links">> => maps:get(<<"links">>, managed()) ++ [
            #{<<"session">> => <<"$2">>, <<"window">> => <<"@2">>, <<"index">> => 0}]},
    with_source(desired(), fun(File) ->
        {ok, Plan} = tmux_workspace_plan:from_state(File, desired(), State,
            #{adopt => [<<"s">>, <<"w">>, <<"p">>]}),
        Map = tmux_workspace_plan:to_map(Plan),
        Bindings = maps:get(<<"bindings">>, Map),
        lists:foreach(fun({Key, Target}) ->
            {ok, Forged} = tmux_workspace_plan:from_map(rehash(
                Map#{<<"bindings">> => Bindings#{Key => Target}})),
            ?assertMatch({error, #{code := invalid_plan, completed := []}},
                tmux_workspace_apply:run(Forged, unopened, #{}))
        end, [{<<"p">>, <<"pane:%2">>}, {<<"w">>, <<"window:@2">>}])
    end).

rehash(Map) ->
    Base = maps:remove(<<"planHash">>, Map),
    Base#{<<"planHash">> => tmux_workspace_wire:digest(Base)}.

with_source(Document, Fun) ->
    File = filename:join(<<"/tmp">>, <<"ltm-plan-",
        (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary,
        ".json">>),
    Source = Document#{sessions => [S#{windows => [W#{panes => [
        maps:merge(maps:remove(launch, P), maps:get(launch, P))
        || P <- maps:get(panes, W)]} || W <- maps:get(windows, S)]}
        || S <- maps:get(sessions, Document)]},
    ok = file:write_file(File, json:encode(Source)),
    try Fun(File) after ok = file:delete(File) end.

desired() ->
    #{version => 1, id => <<"demo">>, endpoint => <<"dev">>, sessions => [
        #{key => <<"s">>, name => <<"work">>, windows => [
            #{key => <<"w">>, name => <<"api">>, panes => [
                #{key => <<"p">>, cwd => <<"/">>,
                    launch => #{argv => [<<"/bin/cat">>]}}]}]}]}.

instance() -> <<"linux-v1:", (binary:copy(<<"0">>, 64))/binary>>.

managed() ->
    [S, W, P] = tmux_workspace_state:desired_nodes(desired()),
    Base = fun(Kind, Id) -> #{<<"kind">> => Kind, <<"id">> => Id,
        <<"name">> => null, <<"parent">> => null, <<"index">> => null,
        <<"layout">> => null, <<"tag">> => null} end,
    R0 = [(Base(<<"session">>, <<"$1">>))#{<<"name">> => <<"work">>},
        (Base(<<"window">>, <<"@1">>))#{<<"name">> => <<"api">>,
            <<"layout">> => layout([cell(<<"%1">>, 80, 24)])},
        (Base(<<"pane">>, <<"%1">>))#{<<"parent">> => <<"@1">>, <<"index">> => 0}],
    State = #{<<"instance">> => instance(), <<"resources">> => R0,
        <<"links">> => [#{<<"session">> => <<"$1">>, <<"window">> => <<"@1">>,
            <<"index">> => 0}]},
    Bindings = #{<<"s">> => <<"session:$1">>, <<"w">> => <<"window:@1">>,
        <<"p">> => <<"pane:%1">>},
    State#{<<"resources">> => [R#{<<"tag">> => tmux_workspace_state:tag(
        desired(), N, Bindings, State)} || {R, N} <- lists:zip(R0, [S, W, P])]}.

layout(Cells) ->
    iolist_to_binary(json:encode(#{<<"V">> => 2, <<"L">> => #{<<"t">> => <<"h">>,
        <<"w">> => 80, <<"h">> => 24, <<"c">> => Cells}})).

cell(Id, Width, Height) ->
    #{<<"t">> => <<"p">>, <<"w">> => Width, <<"h">> => Height, <<"I">> => Id}.
