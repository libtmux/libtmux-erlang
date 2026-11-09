-module(tmux_query_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         complete_graph_and_residuals/1, numeric_and_candidate_equivalence/1,
         recursive_candidate_implication/1, limits_and_read_retry/1,
         framed_field_bytes/1, large_hydration_output/1]).

%% Outer: source codecs, native format arithmetic and owned graph captures.
all() -> [complete_graph_and_residuals, numeric_and_candidate_equivalence,
          recursive_candidate_implication, limits_and_read_retry,
          framed_field_bytes, large_hydration_output].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Path -> Path
    end,
    [{executable, list_to_binary(Executable)} | Config].
end_per_suite(_) -> ok = application:stop(libtmux_erlang).

%% Outer: cross the 1 MiB command bound and qualify explicit isolated recovery.
large_hydration_output(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), fun(Server, Fixture) ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"large">>, launch => #{argv => [<<"/bin/cat">>]}}),
        Id = tmux_model:get(id, Session),
        {ok, #{cleanup := complete, exit_status := 0}} = tmux_test_fixture:command(Fixture,
            [<<"set-option">>, <<"-g">>, <<"@fill">>, <<"x">>]),
        lists:foreach(fun(N) ->
            Args = case N of
                0 -> [<<"list-panes">>, <<"-t">>, <<Id/binary, ":">>,
                    <<"-F">>, <<"#{pane_id}">>];
                _ -> [<<"new-window">>, <<"-d">>, <<"-P">>, <<"-F">>,
                    <<"#{pane_id}">>, <<"-t">>, <<Id/binary, ":">>, <<"/bin/cat">>]
            end,
            {ok, #{stdout := PaneLine, cleanup := complete, exit_status := 0}} =
                tmux_test_fixture:command(Fixture, Args),
            [Target] = binary:split(PaneLine, <<"\n">>, [global, trim_all]),
            {ok, #{cleanup := complete, exit_status := 0}} =
                tmux_test_fixture:command(Fixture, [<<"select-pane">>, <<"-t">>, Target,
                    <<"-T">>, <<"#{p10000:@fill}#{p10000:@fill}#{p10000:@fill}">>])
        end, lists:seq(0, 36)),
        {error, #{code := output_limit, stream := stdout, cleanup := complete,
                  stdout := Prefix}} = tmux_server:snapshot(Server),
        1048576 = byte_size(Prefix),
        {ok, Snapshot} = tmux_server:snapshot(Server,
            #{hydration => isolated, deadline_ms => 60000}),
        Panes = tmux_snapshot:panes(Snapshot),
        37 = length(Panes),
        true = lists:all(fun(Pane) -> byte_size(tmux_model:get(title, Pane)) =:= 30000 end, Panes),
        #{source_calls := Calls, hydration := isolated} = tmux_snapshot:metadata(Snapshot),
        192 = length(Calls)
    end).

framed_field_bytes(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), fun(Server, Fixture) ->
        {ok, Session} = tmux_session:create(Server,
            #{name => <<"frames">>, launch => #{argv => [<<"/bin/cat">>]}}),
        Id = tmux_model:get(id, Session),
        {ok, Version} = tmux_server:version(Server),
        Encoded = tmux_text_codec:field_format(<<"@frame_probe">>),
        Format = <<"#{session_id}\t", Encoded/binary, "\tEND">>,
        lists:foreach(fun(Value) ->
            {ok, #{cleanup := complete}} = tmux_test_fixture:command(Fixture,
                [<<"-u">>, <<"set-option">>, <<"-g">>, <<"@frame_probe">>, Value]),
            {ok, #{stdout := Raw, cleanup := complete}} = tmux_test_fixture:command(Fixture,
                [<<"-u">>, <<"list-sessions">>, <<"-F">>, Format]),
            {ok, [[Id, Value, <<"END">>]]} = tmux_text_codec:columns(Raw, Version, 3, 1)
        end, [<<>>, list_to_binary(lists:seq(1, 255)),
              <<255, "\t\n\\n\\t $HOME #{pid} %end 1 2 3", 254>>])
    end).

complete_graph_and_residuals(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), fun(Server, Fixture) ->
        {ok, S1} = tmux_session:create(Server, #{name => <<"source">>, window_name => <<"skip">>,
            launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, S2} = tmux_session:create(Server, #{name => <<"other">>, window_name => <<"also-skip">>,
            launch => #{argv => [<<"/bin/cat">>]}}),
        Name = <<"target,};#{pid};%end">>,
        {ok, Window} = tmux_window:create(S1,
            #{name => Name, launch => #{argv => [<<"/bin/cat">>]}}),
        {ok, Pane} = tmux_pane:split(Window, #{launch => #{shell => <<>>}}),
        WindowId = tmux_model:get(id, Window),
        PaneId = tmux_model:get(id, Pane),
        S1Id = tmux_model:get(id, S1),
        S2Id = tmux_model:get(id, S2),
        lists:foreach(fun(Target) ->
            {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
                [<<"link-window">>, <<"-d">>, <<"-s">>, WindowId, <<"-t">>, Target])
        end, [<<S1Id/binary, ":7">>, <<S2Id/binary, ":9">>]),
        Criteria = #{name => Name, pane_count => #{gte => 1},
                     panes => #{some => #{pid => none}}},
        Default = tmux_query:limit(1, tmux_query:where(Criteria, tmux_query:windows(Server))),
        Query = tmux_query:pushdown(true, Default),
        Trace = trace:session_create(query_planning, self(), []),
        Boundaries = [{tmux_server, command, 3}, {tmux_observe, get, 3},
                      {tmux_observe, query, 3}, {tmux_observe, snapshot, 2}],
        try
            lists:foreach(fun(MFA) -> 1 = trace:function(Trace, MFA, true, [call_count]) end, Boundaries),
            _ = tmux_query:explain(tmux_query:where(#{width => #{gte => 1}}, Query)),
            lists:foreach(fun(MFA) -> {call_count, 0} = trace:info(Trace, MFA, call_count) end, Boundaries)
        after true = trace:session_destroy(Trace)
        end,
        {Chosen, PushedCalls} = fetch_count(Query),
        [WindowId] = ids(Chosen),
        #{query := #{candidate_count := 3, pushed_down := true, attempt := 1},
          capture_started := Started, capture_finished := Finished} = tmux_select:summary(Chosen),
        true = Started =< Finished,
        1 = tmux_select:count(#{panes => #{count => 2}}, Chosen),
        0 = tmux_select:count(#{panes => #{every => #{pid => none}}}, Chosen),
        0 = tmux_select:count(#{panes => #{none => #{pid => none}}}, Chosen),
        {Local, LocalCalls} = fetch_count(Default),
        [WindowId] = ids(Local),
        #{query := #{pushed_down := false}} = tmux_select:summary(Local),
        true = PushedCalls =:= LocalCalls + 1,
        true = [tmux_model:to_map(R) || R <- tmux_select:to_list(Chosen)] =:=
               [tmux_model:to_map(R) || R <- tmux_select:to_list(Local)],
        PaneQuery = tmux_query:pushdown(true,
            tmux_query:where(#{id => PaneId}, tmux_query:panes(Server))),
        {ok, Panes} = tmux_query:fetch(PaneQuery),
        [PaneId] = ids(Panes),
        #{query := #{candidate_count := 1}} = tmux_select:summary(Panes),
        1 = tmux_select:count(#{window => #{is => #{window_links => #{count => 3}}}}, Panes),
        {ok, Links} = tmux_query:fetch(tmux_query:pushdown(true, tmux_query:where(
            #{session_id => S1Id, window_id => WindowId}, tmux_query:window_links(Server)))),
        [1,7] = [tmux_model:get(index, L) || L <- tmux_select:to_list(Links)],
        #{query := #{pushed_down := true}} = tmux_select:summary(Links),
        {ok, Sessions} = tmux_query:fetch(tmux_query:pushdown(true, tmux_query:where(
            #{id => S1Id, window_links => #{count => 3}}, tmux_query:sessions(Server)))),
        [S1Id] = ids(Sessions),
        #{query := #{pushed_down := true}} = tmux_select:summary(Sessions),
        ok = tmux_server:close(Server),
        1 = tmux_select:count(#{panes => #{count => 2}}, Chosen)
    end).

numeric_and_candidate_equivalence(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), fun(Server, Fixture) ->
        {ok, Session} = tmux_session:create(Server, #{name => <<"numeric">>,
            width => 120, launch => #{argv => [<<"/bin/cat">>]}}),
        Base = tmux_query:pushdown(true, tmux_query:panes(Server)),
        Values = [0,1,9,10,99,100,2147483647,2147483648,9007199254740990,9007199254740991],
        Cases = [{Op, A, B} || Op <- [equals,'not',lt,lte,gt,gte], A <- Values, B <- Values],
        Numeric = [begin
            Q = tmux_query:where(#{width => #{Op => B}}, Base),
            #{candidate := #{format := F, exact := true}} = tmux_query:explain(Q),
            {binary:replace(F, <<"#{pane_width}">>, integer_to_binary(A)), compare(Op,A,B)}
        end || {Op,A,B} <- Cases],
        numeric_batches(Numeric, Fixture),
        {ok, Snapshot} = tmux_server:snapshot(Server),
        Panes = tmux_select:panes(Snapshot),
        [PaneId] = ids(Panes),
        Ids = [PaneId | [<<"%", (integer_to_binary(N))/binary>> || N <- lists:seq(1000,1254)]],
        Native = #{active => true},
        Local = #{title => #{contains => <<"impossible-#{pid},};">>}},
        Conditions = [#{}, #{'or' => []}, #{id => #{in => Ids}}, #{width => #{lt => 10}},
            Native, #{'not' => Native}, Local, #{'not' => Local},
            #{'not' => #{'and' => [Native,Local]}},
            #{'or' => [#{'and' => [Native,Local]},
                       #{'and' => [#{width => #{gte => 100}}, #{title => #{contains => <<>>}}]}]},
            #{window => #{is => #{panes => #{every => #{active => true}}}}}],
        lists:foreach(fun(Criteria) ->
            Q = tmux_query:where(Criteria, Base),
            #{candidate := #{format := Format, exact := Exact}} = tmux_query:explain(Q),
            {ok, #{stdout := Output, exit_status := 0}} = tmux_test_fixture:command(Fixture,
                [<<"list-panes">>, <<"-a">>, <<"-f">>, Format, <<"-F">>, <<"#{pane_id}">>]),
            Candidates = lists:usort(binary:split(Output, <<"\n">>, [global,trim_all])),
            Full = ids(tmux_select:where(Criteria, Panes)),
            [] = Full -- Candidates,
            case Exact of true -> Full = Candidates; false -> ok end
        end, Conditions),
        {ok, _} = tmux_session:kill(Session)
    end).

recursive_candidate_implication(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config),
        fun(Server, Fixture) ->
            Launch = #{argv => [<<"/bin/cat">>]},
            {ok, S1} = tmux_session:create(Server, #{name => <<"recursive">>,
                window_name => <<"initial">>, width => 120, height => 80,
                launch => Launch}),
            {ok, S2} = tmux_session:create(Server, #{name => <<"linked">>,
                window_name => <<"other">>, launch => Launch}),
            {ok, Window} = tmux_window:create(S1,
                #{name => <<"workers">>, launch => Launch}),
            {ok, P1} = tmux_pane:split(Window,
                #{direction => horizontal, launch => Launch}),
            {ok, P2} = tmux_pane:split(Window,
                #{launch => #{shell => <<>>}}),
            Id1 = tmux_model:get(id, P1),
            Id2 = tmux_model:get(id, P2),
            {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
                [<<"select-pane">>, <<"-t">>, Id1, <<"-T">>, <<"needle">>]),
            WindowId = tmux_model:get(id, Window),
            lists:foreach(fun({Session, Index}) ->
                Id = tmux_model:get(id, Session),
                {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
                    [<<"link-window">>, <<"-d">>, <<"-s">>, WindowId,
                     <<"-t">>, <<Id/binary, ":", Index/binary>>])
            end, [{S1, <<"7">>}, {S2, <<"9">>}]),
            SessionId = tmux_model:get(id, S1),
            tmux_test_fixture:with_client(Fixture, SessionId, [], fun(_) ->
                tmux_test_fixture:with_client(Fixture, SessionId, [], fun(_) ->
                    recursive_candidates(Server, Fixture, SessionId, WindowId,
                        Id1, Id2)
                end)
            end)
        end).

recursive_candidates(Server, Fixture, SessionId, WindowId, Id1, Id2) ->
    {ok, Snapshot} = tmux_server:snapshot(Server),
    Panes = tmux_select:panes(Snapshot),
    5 = tmux_select:size(Panes),
    lists:foreach(fun(Pane) ->
        case tmux_model:get(pid, Pane) of
            none -> ok;
            Pid -> ok = tmux_test_fixture:track_process(Fixture, Pid)
        end
    end, tmux_select:to_list(Panes)),
    1 = tmux_select:count(#{pid => none}, Panes),
    1 = tmux_select:count(#{id => WindowId,
        window_links => #{count => 3}}, tmux_select:windows(Snapshot)),
    Leaves = [#{active => true}, #{active => false}, #{index => 0},
        #{width => #{gte => 120}}, #{width => #{lt => 1}},
        #{id => Id1}, #{id => #{in => [Id1, Id2]}},
        #{title => #{contains => <<"needle">>}},
        #{title => #{contains => <<"missing-needle">>}},
        #{pid => #{present => true}}, #{pid => none},
        #{window => #{is => #{window_links =>
            #{count => #{gte => 2}}}}},
        #{window => #{is_not => #{panes =>
            #{every => #{active => true}}}}}],
    Criteria = recursive_conditions(Leaves),
    Base = tmux_query:pushdown(true, tmux_query:panes(Server)),
    Cases = [begin
        Query = tmux_query:where(C, Base),
        #{candidate := Candidate} = tmux_query:explain(Query),
        Candidate#{criteria => C,
            matches => ids(tmux_select:where(C, Panes))}
    end || C <- Criteria],
    true = lists:any(fun(#{exact := Exact, format := F}) ->
        Exact andalso F =/= <<"0">> andalso F =/= <<"1">>
    end, Cases),
    true = lists:any(fun(#{exact := Exact, format := F}) ->
        not Exact andalso F =/= <<"0">> andalso F =/= <<"1">>
    end, Cases),
    lists:foreach(fun(Row) ->
        Target = {tmux_model:get(window_id, Row),
            tmux_model:get(id, Row)},
        candidate_batches(Cases, Target, Fixture)
    end, tmux_select:to_list(Panes)),
    session_window_candidates(Server, Fixture, Snapshot,
        SessionId, WindowId),
    {ok, After} = tmux_server:snapshot(Server),
    Fields = [id, window_id, index, active, width, title, pid],
    BeforeRows = [maps:with(Fields, tmux_model:to_map(P))
        || P <- tmux_snapshot:panes(Snapshot)],
    BeforeRows = [maps:with(Fields, tmux_model:to_map(P))
        || P <- tmux_snapshot:panes(After)],
    BeforeLinks = [tmux_model:to_map(L)
        || L <- tmux_snapshot:window_links(Snapshot)],
    BeforeLinks = [tmux_model:to_map(L)
        || L <- tmux_snapshot:window_links(After)],
    lists:foreach(fun(Entity) ->
        Before = [tmux_model:to_map(Row) || Row <- tmux_snapshot:rows(Entity, Snapshot)],
        Before = [tmux_model:to_map(Row) || Row <- tmux_snapshot:rows(Entity, After)]
    end, [session, window]),
    ct:pal("Native recursive candidates: ~p conditions / ~p panes",
        [length(Cases), tmux_select:size(Panes)]).

session_window_candidates(Server, Fixture, Snapshot, SessionId, WindowId) ->
    Sessions = tmux_select:sessions(Snapshot),
    Windows = tmux_select:windows(Snapshot),
    [0, 2] = lists:sort([tmux_model:get(attached_count, Session)
        || Session <- tmux_select:to_list(Sessions)]),
    1 = tmux_select:count(#{id => WindowId, pane_count => 3}, Windows),
    1 = tmux_select:count(#{id => WindowId,
        window_links => #{count => 3}}, Windows),
    {ok, SelectedSession} = tmux_select:one(#{id => SessionId}, Sessions),
    Created = tmux_model:get(created, SelectedSession),
    Inputs = [
        {session, Sessions, tmux_query:sessions(Server), [
            #{id => SessionId}, #{id => #{in => [SessionId, <<"$999">>]}},
            #{attached_count => 0}, #{attached_count => 2},
            #{attached_count => #{gte => 1}}, #{created => Created},
            #{attached => true}, #{name => #{contains => <<"recursive">>}},
            #{windows => #{some => #{panes => #{some => #{pid => none}}}}},
            #{window_links => #{count => #{gte => 3}}}]},
        {window, Windows, tmux_query:windows(Server), [
            #{id => WindowId}, #{id => #{not_in => [WindowId, <<"@999">>]}},
            #{width => #{gt => 0}}, #{height => #{lt => 1}},
            #{pane_count => 1}, #{pane_count => 3},
            #{name => #{contains => <<"workers">>}},
            #{panes => #{some => #{title => <<"needle">>}}},
            #{panes => #{every => #{pid => #{present => true}}}},
            #{window_links => #{count => #{gte => 2}}}]}
    ],
    lists:foreach(fun({Entity, Selection, Base, Leaves}) ->
        Conditions = recursive_conditions(Leaves),
        Cases = [begin
            Query = tmux_query:where(Criteria, tmux_query:pushdown(true, Base)),
            #{candidate := Candidate} = tmux_query:explain(Query),
            Candidate#{criteria => Criteria,
                matches => ids(tmux_select:where(Criteria, Selection))}
        end || Criteria <- Conditions],
        true = lists:any(fun(#{exact := Exact, format := Format}) ->
            Exact andalso Format =/= <<"0">> andalso Format =/= <<"1">>
        end, Cases),
        true = lists:any(fun(#{exact := Exact, format := Format}) ->
            not Exact andalso Format =/= <<"0">> andalso Format =/= <<"1">>
        end, Cases),
        lists:foreach(fun(Row) ->
            candidate_batches(Cases, {Entity, tmux_model:get(id, Row)}, Fixture)
        end, tmux_select:to_list(Selection)),
        ct:pal("Native recursive candidates: ~p conditions / ~p ~p rows",
            [length(Cases), tmux_select:size(Selection), Entity])
    end, Inputs),
    SessionBase = tmux_query:where(#{attached_count => 2},
        tmux_query:pushdown(true, tmux_query:sessions(Server))),
    _ = fetch_candidate(tmux_query:where(#{window_links => #{count => 3}},
        SessionBase), [SessionId]),
    _ = fetch_candidate(tmux_query:where(#{window_links => #{count => 2}},
        SessionBase), []),
    WindowBase = tmux_query:where(#{pane_count => 3},
        tmux_query:pushdown(true, tmux_query:windows(Server))),
    SelectedWindows = fetch_candidate(tmux_query:where(
        #{window_links => #{count => 3}}, WindowBase), [WindowId]),
    _ = fetch_candidate(tmux_query:where(#{window_links => #{count => 1}},
        WindowBase), []),
    1 = tmux_select:count(#{panes => #{some => #{pid => none}}},
        SelectedWindows).

limits_and_read_retry(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), fun(Server, Fixture) ->
        Query = tmux_query:where(#{width => #{gte => 1}}, tmux_query:panes(Server)),
        {ok, Empty} = tmux_query:fetch(Query),
        0 = tmux_select:size(Empty),
        {ok, _} = tmux_session:create(Server,
            #{name => <<"retry">>, launch => #{argv => [<<"/bin/cat">>]}}),
        {error, #{code := unsupported_consistency}} = tmux_query:fetch(Query, #{consistency => atomic}),
        {error, #{code := capture_limit, limit := max_rows}} = tmux_query:fetch(Query, #{max_rows => 1}),
        {error, #{code := output_limit}} = tmux_query:fetch(Query, #{max_bytes => 1}),
        Hook = <<"set-hook -gu after-list-panes ; new-window -d -t retry: /bin/cat">>,
        set_hook(Fixture, Hook),
        {error, #{code := inconsistent_capture}} = tmux_query:fetch(Query),
        set_hook(Fixture, Hook),
        {ok, Retried} = tmux_query:fetch(Query, #{retry => 1}),
        3 = tmux_select:size(Retried),
        #{query := #{attempt := 2}} = tmux_select:summary(Retried),
        {ok, Limited} = tmux_query:fetch(tmux_query:limit(0, Query)),
        0 = tmux_select:size(Limited),
        ok = tmux_server:close(Server),
        {error, #{code := stale_reference}} = tmux_query:fetch(Query)
    end).

fetch_candidate(Query, Expected) ->
    {ok, Selection} = tmux_query:fetch(Query),
    Expected = ids(Selection),
    #{query := #{candidate_count := 1, pushed_down := true}} =
        tmux_select:summary(Selection),
    Selection.

fetch_count(Query) ->
    Trace = trace:session_create(query_fetch, self(), []),
    Boundary = {tmux_server, command, 3},
    try
        1 = trace:function(Trace, Boundary, true, [call_count]),
        {ok, Selection} = tmux_query:fetch(Query),
        {call_count, Count} = trace:info(Trace, Boundary, call_count),
        {Selection, Count}
    after true = trace:session_destroy(Trace)
    end.

numeric_batches([], _) -> ok;
numeric_batches(Cases, Fixture) ->
    {Batch, Rest} = lists:split(min(32,length(Cases)), Cases),
    Expected = [B || {_, B} <- Batch],
    Expected = boolean_formats([F || {F, _} <- Batch], none, Fixture),
    numeric_batches(Rest, Fixture).

candidate_batches([], _, _) -> ok;
candidate_batches(Cases, {_, Id} = Target, Fixture) ->
    {Batch, Rest} = lists:split(min(32, length(Cases)), Cases),
    Values = boolean_formats([maps:get(format, C) || C <- Batch],
        Target, Fixture),
    lists:foreach(fun({Case, Actual}) ->
        Full = lists:member(Id, maps:get(matches, Case)),
        Detail = #{target => Target, criteria => maps:get(criteria, Case),
            format => maps:get(format, Case), full => Full, candidate => Actual},
        case {Full, Actual, maps:get(exact, Case)} of
            {true, false, _} -> error({candidate_excluded_match, Detail});
            {false, true, true} -> error({candidate_false_exactness, Detail});
            _ -> ok
        end
    end, lists:zip(Batch, Values)),
    candidate_batches(Rest, Target, Fixture).

%% The list commands use the same expansion as -f, without strftime on IDs.
%% Repeated window memberships must produce the same physical-row values.
boolean_formats(Formats, {Entity, Id}, Fixture)
  when Entity =:= session; Entity =:= window ->
    {Command, Arguments, Field} = case Entity of
        session -> {<<"list-sessions">>, [], <<"session_id">>};
        window -> {<<"list-windows">>, [<<"-a">>], <<"window_id">>}
    end,
    Format = iolist_to_binary(lists:join(<<"\t">>,
        [<<"#{", Field/binary, "}">> | Formats])),
    Filter = <<"#{==:#{", Field/binary, "},", Id/binary, "}">>,
    {ok, #{stdout := Output, exit_status := 0}} =
        tmux_test_fixture:command(Fixture,
            [Command | Arguments] ++ [<<"-f">>, Filter, <<"-F">>, Format]),
    Lines = binary:split(Output, <<"\n">>, [global, trim_all]),
    Count = length(Formats),
    [Values] = lists:usort([begin
        [Id | Columns] = binary:split(Line, <<"\t">>, [global]),
        Count = length(Columns),
        [case Value of <<"0">> -> false; <<"1">> -> true end
            || Value <- Columns]
    end || Line <- Lines]),
    Values;
boolean_formats(Formats, Target, Fixture) ->
    Arguments = case Target of
        none -> [];
        {Window, Id} -> [<<"-t">>, Window, <<"-f">>,
            <<"#{==:#{pane_id},", Id/binary, "}">>]
    end,
    Format = iolist_to_binary(lists:join(<<"\t">>,
        [<<"#{pane_id}">> | Formats])),
    {ok, #{stdout := Output, exit_status := 0}} =
        tmux_test_fixture:command(Fixture,
            [<<"list-panes">> | Arguments] ++ [<<"-F">>, Format]),
    [Body, <<>>] = binary:split(Output, <<"\n">>, [global]),
    [SeenId | Values] = binary:split(Body, <<"\t">>, [global]),
    case Target of none -> ok; {_, SeenId} -> ok end,
    Count = length(Formats),
    Count = length(Values),
    [case V of <<"0">> -> false; <<"1">> -> true end || V <- Values].

recursive_conditions(Leaves) ->
    Seed = rand:seed_s(exsss, {1729, 29, 154}),
    {Trees, _} = lists:mapfoldl(fun(_, State) ->
        condition(3, Leaves, State)
    end, Seed, lists:seq(1, 128)),
    [#{}, #{'or' => []}] ++ Leaves ++
        [#{'not' => C} || C <- Leaves] ++ Trees.

condition(0, Leaves, State) ->
    {Index, Next} = rand:uniform_s(length(Leaves), State),
    {lists:nth(Index, Leaves), Next};
condition(Depth, Leaves, State) ->
    {Kind, Next} = rand:uniform_s(4, State),
    case Kind of
        1 -> condition(0, Leaves, Next);
        2 ->
            {Child, Final} = condition(Depth - 1, Leaves, Next),
            {#{'not' => Child}, Final};
        _ ->
            {Left, S1} = condition(Depth - 1, Leaves, Next),
            {Right, Final} = condition(Depth - 1, Leaves, S1),
            Operator = case Kind of 3 -> 'and'; 4 -> 'or' end,
            {#{Operator => [Left, Right]}, Final}
    end.

compare(equals,A,B) -> A =:= B;
compare('not',A,B) -> A =/= B;
compare(lt,A,B) -> A < B;
compare(lte,A,B) -> A =< B;
compare(gt,A,B) -> A > B;
compare(gte,A,B) -> A >= B.
ids(Selection) -> [tmux_model:get(id, R) || R <- tmux_select:to_list(Selection)].
set_hook(Fixture, Hook) ->
    {ok, #{exit_status := 0}} = tmux_test_fixture:command(Fixture,
        [<<"set-hook">>, <<"-g">>, <<"after-list-panes">>, Hook]).
