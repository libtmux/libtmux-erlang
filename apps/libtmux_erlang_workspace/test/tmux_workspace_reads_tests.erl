-module(tmux_workspace_reads_tests).
-compile(nowarn_missing_spec).
-include_lib("eunit/include/eunit.hrl").

bounded_parallel_reads_test() ->
    Parent = self(), Tag = make_ref(),
    {Caller, Monitor} = spawn_monitor(fun() ->
        Values = tmux_workspace_reads:map(fun(N) ->
            Parent ! {Tag, started, self(), N},
            receive {Tag, release} -> N * 2 end
        end, lists:seq(1, 6), #{}),
        Parent ! {Tag, result, Values}
    end),
    try
        First = started(Tag, 3, []),
        ?assertEqual([1, 2, 3], lists:sort([N || {_, N} <- First])),
        lists:foreach(fun({Pid, _}) -> Pid ! {Tag, release} end,
            lists:reverse(First)),
        Second = started(Tag, 3, []),
        ?assertEqual([4, 5, 6], lists:sort([N || {_, N} <- Second])),
        lists:foreach(fun({Pid, _}) -> Pid ! {Tag, release} end,
            lists:reverse(Second)),
        receive {Tag, result, Values} ->
            ?assertEqual(lists:seq(2, 12, 2), Values)
        after 500 -> error(result_missing) end,
        receive {'DOWN', Monitor, process, Caller, normal} -> ok
        after 500 -> error(caller_alive) end
    after
        exit(Caller, kill), erlang:demonitor(Monitor, [flush])
    end.

started(_, 0, Acc) -> Acc;
started(Tag, Count, Acc) ->
    receive {Tag, started, Pid, N} -> started(Tag, Count - 1, [{Pid, N} | Acc])
    after 500 -> error({parallel_reads_missing, 3 - Count}) end.

cleanup_failure_is_not_masked_test() ->
    lists:foreach(fun(Cancelled) ->
        Parent = self(), Tag = make_ref(), Cancel = make_ref(),
        {Caller, Monitor} = spawn_monitor(fun() ->
            Result = try tmux_workspace_reads:map(fun(N) ->
                Parent ! {Tag, started, self(), N},
                receive {Tag, release} -> ok end,
                case N of
                    1 -> throw({workspace_error, #{code => invalid_tag}});
                    3 -> throw({workspace_error, #{code => cleanup_incomplete,
                        cleanup => incomplete}});
                    _ -> N
                end
            end, [1, 2, 3, 4], #{cancel => Cancel})
            catch throw:{workspace_error, Detail} -> Detail end,
            Parent ! {Tag, result, Result}
        end),
        try
            Workers = started(Tag, 3, []),
            true = erlang:suspend_process(Caller),
            case Cancelled of
                true -> Caller ! {tmux_workspace_cancel, Cancel};
                false -> ok
            end,
            [{First, _} | _] = Workers,
            {links, [Coordinator]} = process_info(First, links),
            Joined = erlang:monitor(process, Coordinator),
            lists:foreach(fun({P, _}) -> P ! {Tag, release} end, Workers),
            receive {'DOWN', Joined, process, Coordinator, normal} -> ok
            after 500 -> error(coordinator_alive) end,
            true = erlang:resume_process(Caller),
            receive {Tag, result, Result} ->
                Expected = case Cancelled of true -> cancelled; false -> invalid_tag end,
                ?assertMatch(#{code := Expected, cleanup := incomplete,
                    read_cleanup_failure := #{code := cleanup_incomplete}}, Result)
            after 500 -> error(result_missing) end,
            ?assert(lists:all(fun({P, _}) -> not is_process_alive(P) end, Workers)),
            receive {'DOWN', Monitor, process, Caller, normal} -> ok
            after 500 -> error(caller_alive) end,
            receive {Tag, started, _, 4} -> error(next_batch_started) after 0 -> ok end
        after
            exit(Caller, kill), erlang:demonitor(Monitor, [flush])
        end
    end, [false, true]).

worker_loss_preserves_caller_test() ->
    lists:foreach(fun(Trap) ->
        Parent = self(), Tag = make_ref(),
        {Caller, Monitor} = spawn_monitor(fun() ->
            process_flag(trap_exit, Trap),
            Result = try tmux_workspace_reads:map(fun(N) ->
                Parent ! {Tag, started, self(), N},
                receive {Tag, release} -> N end
            end, [1, 2, 3], #{})
            catch throw:{workspace_error, Detail} -> Detail end,
            Parent ! {Tag, result, Result, process_info(self(), trap_exit)}
        end),
        try
            [{Victim, _} | Rest] = started(Tag, 3, []),
            exit(Victim, kill),
            lists:foreach(fun({P, _}) -> P ! {Tag, release} end, Rest),
            receive {Tag, result, Result, Flag} ->
                ?assertMatch(#{code := metadata_worker_failed,
                    cleanup := unverified}, Result),
                ?assertEqual({trap_exit, Trap}, Flag)
            after 500 -> error(result_missing) end,
            ?assertNot(is_process_alive(Victim)),
            ?assert(lists:all(fun({P, _}) -> not is_process_alive(P) end, Rest)),
            receive {'DOWN', Monitor, process, Caller, normal} -> ok
            after 500 -> error(caller_alive) end
        after
            exit(Caller, kill), erlang:demonitor(Monitor, [flush])
        end
    end, [false, true]).

caller_death_retires_workers_test() ->
    Parent = self(), Tag = make_ref(),
    {Caller, Monitor} = spawn_monitor(fun() ->
        tmux_workspace_reads:map(fun(N) ->
            Parent ! {Tag, started, self(), N},
            receive {Tag, release} -> N end
        end, [1, 2, 3], #{})
    end),
    try
        Workers = started(Tag, 3, []),
        [{First, _} | _] = Workers,
        {links, [Coordinator]} = process_info(First, links),
        Joined = erlang:monitor(process, Coordinator),
        exit(Caller, kill),
        receive {'DOWN', Monitor, process, Caller, killed} -> ok
        after 500 -> error(caller_alive) end,
        receive {'DOWN', Joined, process, Coordinator, normal} -> ok
        after 500 -> error(coordinator_alive) end,
        ?assert(lists:all(fun({P, _}) -> not is_process_alive(P) end, Workers))
    after
        exit(Caller, kill), erlang:demonitor(Monitor, [flush])
    end.
