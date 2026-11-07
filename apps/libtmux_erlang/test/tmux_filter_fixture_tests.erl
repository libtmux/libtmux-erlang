-module(tmux_filter_fixture_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

portable_semantic_fixture_test() ->
    {Snapshot, #{<<"cases">> := Cases, <<"invalid">> := Invalid}} = fixture(),
    lists:foreach(fun(#{<<"name">> := Name, <<"filter">> := Document,
                        <<"expected">> := Expected}) ->
        Entity = entity(maps:get(<<"entity">>, Document)),
        {ok, Filter} = tmux_filter:from_wire(Entity, Document),
        Selection = selection(Entity, Snapshot),
        Actual = ids(tmux_select:where(Filter, Selection)),
        ?assertEqual({Name, Expected}, {Name, Actual}),
        ?assertEqual(Expected, ids(tmux_select:where(Filter, Selection))),
        ?assertEqual({ok, Filter}, tmux_filter:new(Entity, Filter)),
        {ok, Wire} = tmux_json:decode(iolist_to_binary(json:encode(tmux_filter:to_wire(Filter)))),
        ?assertEqual({ok, Filter}, tmux_filter:from_wire(Entity, Wire))
    end, Cases),
    lists:foreach(fun(#{<<"name">> := Name, <<"filter">> := Document,
                        <<"code">> := Code, <<"path">> := Path}) ->
        Entity = entity(maps:get(<<"entity">>, Document)),
        {error, Detail} = tmux_filter:from_wire(Entity, Document),
        ?assertEqual({Name, Code, Path},
            {Name, atom_to_binary(maps:get(code, Detail)), maps:get(path, Detail)})
    end, Invalid).

composed_round_trip_property_test() ->
    {Snapshot, _} = fixture(),
    Panes = tmux_select:panes(Snapshot),
    Fragments = [#{}, #{width => #{gte => 100.0, lt => 130}},
        #{pid => #{in => [none, 101]}}, #{title => #{ends_with => <<>>}},
        #{window => #{is => #{panes => #{count => #{gte => 2}}}}},
        #{current_path => <<0, 255>>}],
    Criteria = Fragments ++ [#{'not' => A} || A <- Fragments] ++
        [#{Op => [A, B]} || Op <- ['and', 'or'], A <- Fragments, B <- Fragments],
    lists:foreach(fun(C) ->
        {ok, F} = tmux_filter:new(pane, C),
        {ok, Document} = tmux_json:decode(iolist_to_binary(json:encode(tmux_filter:to_wire(F)))),
        {ok, RoundTrip} = tmux_filter:from_wire(pane, Document),
        ?assertEqual(F, RoundTrip),
        Selected = tmux_select:where(F, Panes),
        ?assertEqual(ids(Selected), ids(tmux_select:where(RoundTrip, Panes))),
        ?assertEqual(ids(Selected), ids(tmux_select:where(F, Selected)))
    end, Criteria).

fixture() ->
    {ok, Bytes} = file:read_file("test/fixtures/filters-v1.json"),
    {ok, #{<<"version">> := 1, <<"graph">> := Graph} = Fixture} = tmux_json:decode(Bytes),
    Tables = maps:from_list([{Entity, [row(Entity, Document) || Document <- maps:get(
        tmux_schema_data:wire_entity(Entity), Graph)]} || Entity <- tmux_schema_data:entities()]),
    {ok, Snapshot} = tmux_snapshot:build(Tables, #{origin => make_ref(), id => make_ref(),
                                                generation => make_ref(), graph => complete}),
    {Snapshot, Fixture}.

row(Entity, Document) ->
    Schema = tmux_schema_data:fields(Entity),
    Values = maps:fold(fun(Name, #{wire := Wire} = Meta, Acc) ->
        case maps:find(Wire, Document) of
            error -> Acc;
            {ok, Value} ->
                Decoded = case {maps:get(type, Meta), Value} of
                    {bytes, #{<<"base64">> := Binary}} -> base64:decode(Binary);
                    {_, null} -> none;
                    _ -> Value
                end,
                Acc#{Name => Decoded}
        end
    end, #{}, Schema),
    ?assertEqual(map_size(Document), map_size(Values)),
    {ok, Row} = tmux_model:new(Entity, Values),
    Row.

entity(Wire) ->
    [Entity] = [E || E <- tmux_schema_data:entities(), tmux_schema_data:wire_entity(E) =:= Wire],
    Entity.
selection(session, Snapshot) -> tmux_select:sessions(Snapshot);
selection(window, Snapshot) -> tmux_select:windows(Snapshot);
selection(window_link, Snapshot) -> tmux_select:window_links(Snapshot);
selection(pane, Snapshot) -> tmux_select:panes(Snapshot).
ids(Selection) -> [tmux_model:get(id, Row) || Row <- tmux_select:to_list(Selection)].
