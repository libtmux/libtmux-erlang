-module(tmux_scope_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

callback_and_cleanup_run_once_in_caller_test() ->
    Caller = self(),
    Tag = make_ref(),
    Actual = tmux_scope:run(fun() ->
        Caller = self(),
        Caller ! {Tag, primary},
        {error, ordinary_value}
    end, fun() -> Caller = self(), Caller ! {Tag, cleanup}, ok end),
    ?assertEqual({ok, {error, ordinary_value}}, Actual),
    receive {Tag, primary} -> ok after 0 -> error(missing_primary) end,
    receive {Tag, cleanup} -> ok after 0 -> error(missing_cleanup) end,
    receive {Tag, _} -> error(duplicate_callback) after 0 -> ok end.

cleanup_error_preserves_value_test() ->
    ?assertEqual({error, #{code => scope_cleanup_failed,
        primary => {ok, completed_value}, cleanup => {error, enoent}}},
        tmux_scope:run(fun() -> completed_value end, fun() -> {error, enoent} end)),
    ?assertMatch({error, #{cleanup := {error, #{code := invalid_cleanup_result,
                                             value := {ok, unnormalized}}}}},
        tmux_scope:run(fun() -> completed_value end,
                       fun() -> {ok, unnormalized} end)).

cleanup_exception_preserves_both_stacks_test() ->
    {error, #{primary := {exception, error, primary_failure, PrimaryStack},
              cleanup := {exception, throw, cleanup_failure, CleanupStack}}} =
        tmux_scope:run(fun() -> error(primary_failure) end,
                       fun() -> throw(cleanup_failure) end),
    ?assertMatch([{?MODULE, _, _, _} | _], PrimaryStack),
    ?assertMatch([{?MODULE, _, _, _} | _], CleanupStack).

nested_cleanup_failures_remain_observable_test() ->
    {error, #{primary := {exception, error, {badmatch, {error, Inner}}, _},
              cleanup := {error, outer_cleanup}}} = tmux_scope:run(fun() ->
        {ok, _} = tmux_scope:run(fun() -> error(original_failure) end,
                                 fun() -> {error, inner_cleanup} end)
    end, fun() -> {error, outer_cleanup} end),
    ?assertMatch(#{primary := {exception, error, original_failure, [_ | _]},
                   cleanup := {error, inner_cleanup}}, Inner).

raising_scope_preserves_cleanup_errors_test() ->
    Failure = try tmux_scope:run_or_error(fun() -> error(original_failure) end,
        fun() -> {error, cleanup_failure} end) of
        Value -> error({unexpected_success, Value})
    catch error:{scope_cleanup_failed, Detail} -> Detail
    end,
    ?assertMatch(#{primary := {exception, error, original_failure, [_ | _]},
                   cleanup := {error, cleanup_failure}}, Failure).
