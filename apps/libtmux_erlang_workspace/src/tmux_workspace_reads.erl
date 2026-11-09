-module(tmux_workspace_reads).
-moduledoc false.
-export([map/3]).

%% The caller gates each batch. Its trap_exit flag and unrelated messages stay
%% untouched; a private coordinator owns the linked workers for that batch.
%% Three default core output reservations fit its 8 MiB connection budget.
-spec map(fun((A) -> B), [A], map()) -> [B].
map(Function, Items, Options) -> map(Function, Items, Options, []).

map(_, [], _, Acc) -> lists:reverse(Acc);
map(Function, Items, Options, Acc) ->
    case cancelled(Options) of
        true -> failure(#{code => cancelled}, []);
        false -> ok
    end,
    {Batch, Rest} = batch(Items, 3, []),
    Caller = self(), Token = make_ref(),
    {Coordinator, Monitor} = spawn_monitor(fun() ->
        coordinate(Caller, Token, Function, Batch)
    end),
    {Outcomes, Cancelled} = await(Coordinator, Monitor, Token, Options, pending, false),
    case Cancelled orelse cancelled(Options) of
        true -> failure(#{code => cancelled}, Outcomes);
        false -> ok
    end,
    Values = [case Outcome of
        {ok, Value} -> Value;
        {error, Detail} -> failure(Detail, Outcomes)
    end || Outcome <- Outcomes],
    map(Function, Rest, Options, lists:reverse(Values, Acc)).

batch(Rest, 0, Acc) -> {lists:reverse(Acc), Rest};
batch([], _, Acc) -> {lists:reverse(Acc), []};
batch([Item | Rest], Left, Acc) -> batch(Rest, Left - 1, [Item | Acc]).

cancelled(Options) ->
    case maps:get(cancel, Options, none) of
        Ref when is_reference(Ref) ->
            receive {tmux_workspace_cancel, Ref} -> true after 0 -> false end;
        _ -> false
    end.

await(Coordinator, Monitor, Token, Options, Result, Cancelled) ->
    Cancel = maps:get(cancel, Options, none),
    receive
        {Token, Coordinator, Outcomes} ->
            await(Coordinator, Monitor, Token, Options, Outcomes, Cancelled);
        {tmux_workspace_cancel, Cancel} when is_reference(Cancel) ->
            await(Coordinator, Monitor, Token, Options, Result, true);
        {'DOWN', Monitor, process, Coordinator, normal} when Result =/= pending ->
            {Result, Cancelled};
        {'DOWN', Monitor, process, Coordinator, Reason} ->
            Known = case Result of pending -> []; _ -> Result end,
            failure(#{code => metadata_coordinator_failed, reason => Reason,
                cleanup => unverified}, Known)
    end.

coordinate(Caller, Token, Function, Batch) ->
    process_flag(trap_exit, true),
    CallerMonitor = erlang:monitor(process, Caller),
    Coordinator = self(),
    Jobs = maps:from_list([begin
        {Pid, Monitor} = spawn_opt(fun() ->
            Outcome = try {ok, Function(Item)}
            catch
                throw:{workspace_error, Detail} -> {error, Detail};
                Class:Reason -> {error, #{code => metadata_worker_exception,
                    class => Class, reason => Reason, cleanup => unverified}}
            end,
            Coordinator ! {Token, self(), Outcome}
        end, [link, monitor]),
        {Pid, {Monitor, Index}}
    end || {Index, Item} <- lists:enumerate(Batch)]),
    try
        case join(Caller, CallerMonitor, Token, Jobs, #{}, true) of
            {Results, true} ->
                Caller ! {Token, self(), [maps:get(I, Results)
                    || I <- lists:seq(1, length(Batch))]};
            {_, false} -> ok
        end
    after
        %% Also covers a coordinator exception. Uncatchable coordinator death
        %% propagates through links to workers whose trap_exit is false.
        maps:foreach(fun(Pid, _) -> exit(Pid, kill) end, Jobs),
        erlang:demonitor(CallerMonitor, [flush])
    end.

join(_, _, _, Jobs, Results, Alive) when map_size(Jobs) =:= 0 -> {Results, Alive};
join(Caller, CallerMonitor, Token, Jobs, Results, Alive) ->
    receive
        {Token, Pid, Outcome} when is_map_key(Pid, Jobs) ->
            {_, Index} = maps:get(Pid, Jobs),
            join(Caller, CallerMonitor, Token, Jobs, Results#{Index => Outcome}, Alive);
        {'DOWN', CallerMonitor, process, Caller, _} ->
            maps:foreach(fun(Pid, _) -> exit(Pid, kill) end, Jobs),
            join(Caller, CallerMonitor, Token, Jobs, Results, false);
        {'DOWN', Monitor, process, Pid, Reason} when is_map_key(Pid, Jobs) ->
            case maps:get(Pid, Jobs) of
                {Monitor, Index} ->
                    Next = case maps:is_key(Index, Results) of
                        true -> Results;
                        false -> Results#{Index => {error, #{code => metadata_worker_failed,
                            reason => Reason, cleanup => unverified}}}
                    end,
                    join(Caller, CallerMonitor, Token, maps:remove(Pid, Jobs), Next, Alive);
                _ -> join(Caller, CallerMonitor, Token, Jobs, Results, Alive)
            end;
        {'EXIT', Pid, _} when is_map_key(Pid, Jobs) ->
            join(Caller, CallerMonitor, Token, Jobs, Results, Alive)
    end.

-spec failure(map(), [{ok, term()} | {error, map()}]) -> no_return().
failure(Detail, Outcomes) ->
    Errors = [Error || {error, Error} <- Outcomes],
    Worst = lists:foldl(fun(Error, Acc) ->
        Cleanup = maps:get(cleanup, Error, complete),
        case rank(Cleanup) > rank(Acc) of true -> Cleanup; false -> Acc end
    end, maps:get(cleanup, Detail, complete), Errors),
    Base = Detail#{cleanup => Worst, path => maps:get(path, Detail, [])},
    WithRead = case {maps:get(code, Detail), Errors} of
        {cancelled, [First | _]} -> Base#{read_failure => First};
        _ -> Base
    end,
    WithCleanup = case [Error || Error <- Errors,
            maps:get(cleanup, Error, complete) =:= Worst, Worst =/= complete] of
        [CleanupError | _] -> WithRead#{read_cleanup_failure =>
            maps:with([code, cleanup, cause, reason, phase, outcome], CleanupError)};
        [] -> WithRead
    end,
    throw({workspace_error, WithCleanup}).

rank(complete) -> 0;
rank(unverified) -> 1;
rank(incomplete) -> 2.
