-module(prop_tmux_graph).
-compile(nowarn_missing_spec).
-include_lib("proper/include/proper.hrl").
-export([prop_graph_filters/0, prop_graph_quantifiers/0]).

prop_graph_filters() ->
    ?FORALL({Graph, Entity, A, B}, graph_case(),
        begin
            Snapshot = snapshot(Graph),
            Selection = selection(Entity, Snapshot),
            {ok, Filter} = tmux_filter:new(Entity, A),
            Bytes = iolist_to_binary(json:encode(tmux_filter:to_wire(Filter))),
            {ok, Document} = tmux_json:decode(Bytes),
            {ok, Decoded} = tmux_filter:from_wire(Entity, Document),
            {ok, Other} = tmux_filter:new(Entity, B),
            {ok, Conjoined} = tmux_filter:conjoin(Filter, Other),
            Together = #{'and' => [A, B]},
            Expected = expected(Entity, Together, Graph),
            aggregate([Entity | labels(Graph)],
                agrees(Entity, A, Graph, Selection) andalso
                keys(tmux_select:where(Decoded, Selection)) =:=
                    expected(Entity, A, Graph) andalso
                keys(tmux_select:where(Together, Selection))
                    =:= Expected andalso
                keys(tmux_select:where(Conjoined, Selection))
                    =:= Expected andalso
                keys(tmux_select:where(B,
                    tmux_select:where(A, Selection))) =:= Expected)
        end).

prop_graph_quantifiers() ->
    ?FORALL({Graph, Active, Command, Minimum},
        {graph(), boolean(), command(), choose(0, 5)},
        begin
            Snapshot = snapshot(Graph),
            Both = #{active => Active, current_command => Command},
            Left = #{panes => #{some => #{active => Active}}},
            Right = #{panes => #{some => #{current_command => Command}}},
            Independent = #{'and' => [Left, Right]},
            {ok, A} = tmux_filter:new(window, Left),
            {ok, B} = tmux_filter:new(window, Right),
            {ok, Conjoined} = tmux_filter:conjoin(A, B),
            Cases = [
                {window, #{panes => #{some => Both}}},
                {window, Independent},
                {window, #{panes => #{every => #{active => Active}}}},
                {window, #{panes => #{none => #{active => Active}}}},
                {window, #{panes => #{count => #{gte => Minimum}}}},
                {session, #{windows => #{count => #{gte => Minimum}}}},
                {session, #{window_links => #{count => #{gte => Minimum}}}}
            ],
            aggregate(labels(Graph),
                keys(tmux_select:where(Conjoined, selection(window, Snapshot)))
                    =:= expected(window, Independent, Graph) andalso
                lists:all(fun({Entity, Criteria}) ->
                agrees(Entity, Criteria, Graph, selection(Entity, Snapshot))
            end, Cases))
        end).

graph_case() ->
    ?LET(Entity, elements([session, window, window_link, pane]),
        ?LET({Graph, A, B}, {graph(), tree(Entity, 3), tree(Entity, 3)},
            {Graph, Entity, A, B})).

graph() ->
    ?LET({S, W}, {choose(0, 3), choose(0, 4)},
        ?LET({Windows, Sessions},
            {vector(W, {name(), choose(0, 200),
                ?LET(N, choose(0, 4), vector(N,
                    {boolean(), command(), choose(0, 200),
                        oneof([exactly(none), choose(1, 1000)])}))}),
             vector(S, {name(), choose(0, 3), memberships(W)})},
            graph(Windows, Sessions))).

memberships(0) -> exactly([]);
memberships(W) -> ?LET(N, choose(0, 5), vector(N, choose(1, W))).

graph(Windows, Sessions) ->
    #{window => [#{id => id($@, W), name => Name, width => Width,
                   pane_count => length(Panes)}
        || {W, {Name, Width, Panes}} <:- lists:enumerate(Windows)],
      session => [#{id => id($$, S), name => Name,
                    attached_count => Count, attached => Count > 0}
        || {S, {Name, Count, _}} <:- lists:enumerate(Sessions)],
      window_link => lists:append([
        [#{session_id => id($$, S), window_id => id($@, W),
           index => I - 1, active => I =:= 1}
            || {I, W} <:- lists:enumerate(Links)]
        || {S, {_, _, Links}} <:- lists:enumerate(Sessions)]),
      pane => lists:append([
        [#{id => id($%, W * 10 + I), window_id => id($@, W),
           index => I - 1, active => Active, current_command => Command,
           width => Width, pid => Pid}
            || {I, {Active, Command, Width, Pid}} <:- lists:enumerate(Panes)]
        || {W, {_, _, Panes}} <:- lists:enumerate(Windows)])}.

id(Prefix, N) -> <<Prefix, (integer_to_binary(N * 7))/binary>>.
name() -> elements([<<"api">>, <<"web">>, <<"scratch">>]).
command() -> elements([<<"vim">>, <<"cat">>, <<"nvim">>]).

tree(Entity, 0) -> leaf(Entity);
tree(Entity, Depth) ->
    frequency([
        {3, leaf(Entity)},
        {1, ?LET({A, B}, {tree(Entity, Depth - 1), tree(Entity, Depth - 1)},
            #{'and' => [A, B]})},
        {1, ?LET({A, B}, {tree(Entity, Depth - 1), tree(Entity, Depth - 1)},
            #{'or' => [A, B]})},
        {1, ?LET(A, tree(Entity, Depth - 1), #{'not' => A})},
        {3, relation(Entity, Depth - 1)}
    ]).

leaf(Entity) ->
    oneof([elements([#{}, #{'and' => []}, #{'or' => []}]), field(Entity)]).

field(session) ->
    oneof([?LET(N, choose(0, 3), #{attached_count => #{gte => N}}),
           ?LET(B, boolean(), #{attached => B}),
           ?LET(Name, name(), #{name => Name})]);
field(window) ->
    oneof([?LET(N, choose(0, 200), #{width => #{lt => N}}),
           ?LET(Name, name(), #{name => #{'not' => Name}})]);
field(window_link) ->
    oneof([?LET(N, choose(0, 5), #{index => #{gte => N}}),
           ?LET(B, boolean(), #{active => B})]);
field(pane) ->
    oneof([?LET(N, choose(0, 200), #{width => #{gte => N}}),
           ?LET(B, boolean(), #{active => B}),
           ?LET(Command, command(), #{current_command => Command}),
           ?LET(B, boolean(), #{pid => #{present => B}})]).

relation(Entity, Depth) ->
    ?LET({Name, Kind, Target}, elements(relations(Entity)),
        case Kind of
            many -> oneof([
                ?LET({Op, Child},
                    {elements([some, every, none]), tree(Target, Depth)},
                    #{Name => #{Op => Child}}),
                ?LET(N, choose(0, 5), #{Name => #{count => #{gte => N}}})]);
            one -> ?LET({Op, Child},
                {elements([is, is_not]), tree(Target, Depth)},
                #{Name => #{Op => Child}})
        end).

relations(session) -> [{windows, many, window},
                       {window_links, many, window_link}];
relations(window) -> [{panes, many, pane}, {window_links, many, window_link}];
relations(window_link) -> [{session, one, session}, {window, one, window}];
relations(pane) -> [{window, one, window}].

snapshot(Graph) ->
    %% Reverse input to check canonical output independently of input order.
    Rows = maps:map(fun(Entity, Values) ->
        [begin {ok, Row} = tmux_model:new(Entity, V), Row end
            || V <- lists:reverse(Values)]
    end, Graph),
    {ok, Snapshot} = tmux_snapshot:build(Rows,
        #{origin => make_ref(), id => make_ref(), graph => complete}),
    Snapshot.

selection(session, S) -> tmux_select:sessions(S);
selection(window, S) -> tmux_select:windows(S);
selection(window_link, S) -> tmux_select:window_links(S);
selection(pane, S) -> tmux_select:panes(S).

agrees(Entity, Criteria, Graph, Selection) ->
    keys(tmux_select:where(Criteria, Selection)) =:=
        expected(Entity, Criteria, Graph).

keys(Selection) ->
    [key(tmux_model:entity(Row), tmux_model:to_map(Row))
        || Row <- tmux_select:to_list(Selection)].

key(window_link, Row) ->
    {maps:get(session_id, Row), maps:get(index, Row), maps:get(window_id, Row)};
key(_, Row) -> maps:get(id, Row).

%% This interpreter reads input criteria and plain foreign keys. It does not
%% use normalized expressions, model getters or snapshot relation indexes.
expected(Entity, Criteria, Graph) ->
    [key(Entity, Row) || Row <- maps:get(Entity, Graph),
        matches(Criteria, Entity, Row, Graph)].

matches(Criteria, Entity, Row, Graph) ->
    lists:all(fun({Name, Value}) ->
        clause(Name, Value, Entity, Row, Graph)
    end, maps:to_list(Criteria)).

clause('and', Children, E, R, G) ->
    not lists:member(false, [matches(C, E, R, G) || C <- Children]);
clause('or', Children, E, R, G) ->
    lists:member(true, [matches(C, E, R, G) || C <- Children]);
clause('not', Child, E, R, G) -> not matches(Child, E, R, G);
clause(Name, Value, Entity, Row, Graph) ->
    case maps:find(Name, Row) of
        {ok, Actual} -> scalar(Value, Actual);
        error ->
            {Target, Children} = related(Entity, Name, Row, Graph),
            lists:all(fun
                ({count, Test}) -> scalar(Test, length(Children));
                ({Op, Child}) ->
                    Results = [matches(Child, Target, C, Graph)
                        || C <- Children],
                    case Op of
                        some -> lists:member(true, Results);
                        is -> lists:member(true, Results);
                        every -> not lists:member(false, Results);
                        none -> not lists:member(true, Results);
                        is_not -> not lists:member(true, Results)
                    end
            end, maps:to_list(Value))
    end.

scalar(Tests, Actual) when is_map(Tests) ->
    lists:all(fun
        ({gte, N}) -> Actual >= N;
        ({lt, N}) -> Actual < N;
        ({'not', Value}) -> Actual =/= Value;
        ({present, Present}) -> (Actual =/= none) =:= Present
    end, maps:to_list(Tests));
scalar(Expected, Actual) -> Expected =:= Actual.

related(session, windows, #{id := Id}, G) ->
    Memberships = [maps:get(window_id, L) || L <- maps:get(window_link, G),
        maps:get(session_id, L) =:= Id],
    {window, [W || W <- maps:get(window, G),
        lists:member(maps:get(id, W), Memberships)]};
related(session, window_links, #{id := Id}, G) ->
    {window_link, [L || L <- maps:get(window_link, G),
        maps:get(session_id, L) =:= Id]};
related(window, panes, #{id := Id}, G) ->
    {pane, [P || P <- maps:get(pane, G), maps:get(window_id, P) =:= Id]};
related(window, window_links, #{id := Id}, G) ->
    {window_link, [L || L <- maps:get(window_link, G),
        maps:get(window_id, L) =:= Id]};
related(Entity, Name, Row, G) ->
    {Target, Foreign} = case {Entity, Name} of
        {pane, window} -> {window, window_id};
        {window_link, session} -> {session, session_id};
        {window_link, window} -> {window, window_id}
    end,
    {Target, [R || R <- maps:get(Target, G),
        maps:get(id, R) =:= maps:get(Foreign, Row)]}.

labels(#{session := Sessions, window := Windows, window_link := Links}) ->
    [Label || {Label, true} <- [
        {empty_windows, lists:any(fun(#{pane_count := N}) -> N =:= 0 end,
            Windows)},
        {no_windows, Windows =:= []},
        {repeated_memberships, lists:any(fun(#{id := Id}) ->
            Ids = [maps:get(window_id, L) || L <- Links,
                maps:get(session_id, L) =:= Id],
            length(Ids) > length(lists:usort(Ids))
        end, Sessions)},
        {shared_windows, lists:any(fun(#{id := Id}) ->
            length(lists:usort([maps:get(session_id, L) || L <- Links,
                maps:get(window_id, L) =:= Id])) > 1
        end, Windows)}
    ]].
