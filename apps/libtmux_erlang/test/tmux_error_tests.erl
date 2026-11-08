-module(tmux_error_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

native_error_explanations_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%1">>}),
    Empty = tmux_select:from_list(pane, []),
    Rows = tmux_select:from_list(pane, [Pane]),
    Criteria = #{active => #{contains => <<"yes">>}},
    {error, Detail} = tmux_filter:new(pane, Criteria),
    {error, CommandDetail} = tmux_command:validate(not_a_command),
    Cases = [
        {fun() -> tmux_filter:new_or_error(pane, Criteria) end,
            {bad_filter, Detail}, [<<"active">>, <<"contains">>, <<"equals">>]},
        {fun() -> tmux_select:where(Criteria, Rows) end,
            {bad_filter, Detail}, [<<"active">>, <<"contains">>]},
        {fun() -> tmux_query:limit(-1, tmux_query:panes(unopened)) end,
            {bad_query_limit, -1}, [<<"0 through 65536">>]},
        {fun() -> tmux_select:one_or_error(Empty) end,
            no_match, [<<"No row matched">>]},
        {fun() -> tmux_select:one_or_error(tmux_select:from_list(pane, [Pane, Pane])) end,
            {multiple_matches, #{at_least => 2}}, [<<"More than one row matched">>]},
        {fun() -> tmux_model:get(not_a_field, Pane) end,
            {unknown_field, pane, not_a_field}, [<<"pane">>, <<"not_a_field">>]},
        {fun() -> tmux_select:from_list(pane, [not_a_row]) end,
            {bad_selection, #{code => invalid_row, path => [0]}}, [<<"Invalid selection">>]},
        {fun() -> tmux_command:argv(not_a_command) end,
            {invalid_command, CommandDetail}, [<<"Invalid command">>]}
    ],
    lists:foreach(fun({Function, Expected, Fragments}) ->
        {Reason, Stack} = exception(Function),
        ?assertEqual(Expected, Reason),
        check(Reason, Stack, Fragments)
    end, Cases),
    ?assertEqual(#{}, tmux_error:format_error(future_reason, [])),
    ?assertEqual(#{}, tmux_error:format_error({bad_filter, unexpected_detail}, [])).

coverage_and_cleanup_explanations_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%1">>}),
    Rows = tmux_select:from_list(pane, [Pane]),
    {Coverage, CoverageStack} = exception(fun() ->
        tmux_select:where(#{width => #{gte => 80}}, Rows)
    end),
    ?assertMatch({incomplete_snapshot, #{code := incomplete_snapshot}}, Coverage),
    check(Coverage, CoverageStack, [<<"width">>, <<"not_loaded">>]),
    {Cleanup, CleanupStack} = exception(fun() ->
        tmux_scope:run_or_error(fun() -> error(original_failure) end,
            fun() -> {error, cleanup_failure} end)
    end),
    ?assertMatch({scope_cleanup_failed, #{primary := {exception, error,
        original_failure, [_ | _]}, cleanup := {error, cleanup_failure}}}, Cleanup),
    check(Cleanup, CleanupStack, [<<"cleanup">>, <<"primary">>]).

callback_exceptions_keep_their_stack_test() ->
    {ok, Pane} = tmux_model:pane(#{id => <<"%1">>}),
    Rows = tmux_select:from_list(pane, [Pane]),
    {callback_failure, Stack} = exception(fun() ->
        tmux_select:filter(fun callback_failure/1, Rows)
    end),
    ?assertMatch([{?MODULE, callback_failure, 1, _} | _], Stack),
    [{_, _, _, Info} | _] = Stack,
    ?assertNotEqual(tmux_error, maps:get(module,
        proplists:get_value(error_info, Info, #{}), none)).

callback_failure(_) -> error(callback_failure).

exception(Function) ->
    try Function() of
        Value -> error({expected_exception, Value})
    catch error:Reason:Stack -> {Reason, Stack}
    end.

check(Reason, [{_, _, _, Info} | _] = Stack, Fragments) ->
    ?assertMatch(#{module := tmux_error}, proplists:get_value(error_info, Info, #{})),
    Text = unicode:characters_to_binary(erl_error:format_exception(error, Reason, Stack)),
    lists:foreach(fun(Fragment) ->
        ?assertNotEqual(nomatch, binary:match(Text, Fragment))
    end, Fragments),
    #{general := General} = tmux_error:format_error(Reason, Stack),
    ?assert(byte_size(unicode:characters_to_binary(General)) > 0).
