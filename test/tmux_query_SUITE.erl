-module(tmux_query_SUITE).
-compile(nowarn_missing_spec).
-export([all/0, init_per_suite/1, end_per_suite/1,
         complete_graph_and_residuals/1, numeric_and_candidate_equivalence/1,
         limits_and_read_retry/1]).

%% Outer: source codecs, native format arithmetic and owned graph captures.
all() -> [complete_graph_and_residuals, numeric_and_candidate_equivalence, limits_and_read_retry].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(libtmux_erlang),
    Executable = case os:getenv("LIBTMUX_TEST_TMUX") of
        false -> os:find_executable("tmux"); Path -> Path
    end,
    [{executable, list_to_binary(Executable)} | Config].
end_per_suite(_) -> ok = application:stop(libtmux_erlang).

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
        Query = tmux_query:limit(1, tmux_query:where(Criteria, tmux_query:windows(Server))),
        Trace = trace:session_create(query_planning, self(), []),
        Boundaries = [{tmux_server, command, 3}, {tmux_observe, get, 3},
                      {tmux_observe, query, 3}, {tmux_observe, snapshot, 2}],
        try
            lists:foreach(fun(MFA) -> 1 = trace:function(Trace, MFA, true, [call_count]) end, Boundaries),
            _ = tmux_query:explain(tmux_query:where(#{width => #{gte => 1}}, Query)),
            lists:foreach(fun(MFA) -> {call_count, 0} = trace:info(Trace, MFA, call_count) end, Boundaries)
        after true = trace:session_destroy(Trace)
        end,
        {ok, Chosen} = tmux_query:fetch(Query),
        [WindowId] = ids(Chosen),
        #{query := #{candidate_count := 3, pushed_down := true, attempt := 1},
          capture_started := Started, capture_finished := Finished} = tmux_select:summary(Chosen),
        true = Started =< Finished,
        1 = tmux_select:count(#{panes => #{count => 2}}, Chosen),
        0 = tmux_select:count(#{panes => #{every => #{pid => none}}}, Chosen),
        0 = tmux_select:count(#{panes => #{none => #{pid => none}}}, Chosen),
        {ok, Local} = tmux_query:fetch(tmux_query:pushdown(false, Query)),
        [WindowId] = ids(Local),
        true = [tmux_model:to_map(R) || R <- tmux_select:to_list(Chosen)] =:=
               [tmux_model:to_map(R) || R <- tmux_select:to_list(Local)],
        {ok, Panes} = tmux_query:fetch(tmux_query:where(#{id => PaneId}, tmux_query:panes(Server))),
        [PaneId] = ids(Panes),
        #{query := #{candidate_count := 1}} = tmux_select:summary(Panes),
        1 = tmux_select:count(#{window => #{is => #{window_links => #{count => 3}}}}, Panes),
        {ok, Links} = tmux_query:fetch(tmux_query:where(
            #{session_id => S1Id, window_id => WindowId}, tmux_query:window_links(Server))),
        [1,7] = [tmux_model:get(index, L) || L <- tmux_select:to_list(Links)],
        {ok, Sessions} = tmux_query:fetch(tmux_query:where(
            #{id => S1Id, window_links => #{count => 3}}, tmux_query:sessions(Server))),
        [S1Id] = ids(Sessions),
        ok = tmux_server:close(Server),
        1 = tmux_select:count(#{panes => #{count => 2}}, Chosen)
    end).

numeric_and_candidate_equivalence(Config) ->
    tmux_test_fixture:with_server(proplists:get_value(executable, Config), fun(Server, Fixture) ->
        {ok, Session} = tmux_session:create(Server, #{name => <<"numeric">>,
            width => 120, launch => #{argv => [<<"/bin/cat">>]}}),
        Values = [0,1,9,10,99,100,2147483647,2147483648,9007199254740990,9007199254740991],
        Cases = [{Op, A, B} || Op <- [equals,'not',lt,lte,gt,gte], A <- Values, B <- Values],
        Numeric = [begin
            Q = tmux_query:where(#{width => #{Op => B}}, tmux_query:panes(Server)),
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
            Q = tmux_query:where(Criteria, tmux_query:panes(Server)),
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

numeric_batches([], _) -> ok;
numeric_batches(Cases, Fixture) ->
    {Batch, Rest} = lists:split(min(32,length(Cases)), Cases),
    Format = iolist_to_binary(lists:join(<<"\t">>, [F || {F,_} <- Batch])),
    Expected = iolist_to_binary(lists:join(<<"\t">>,
        [case B of true -> <<"1">>; false -> <<"0">> end || {_,B} <- Batch])),
    {ok, #{stdout := Output, exit_status := 0}} =
        tmux_test_fixture:command(Fixture, [<<"display-message">>, <<"-p">>, <<"-F">>, Format]),
    Size = byte_size(Expected),
    <<Expected:Size/binary, "\n">> = Output,
    numeric_batches(Rest, Fixture).

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
