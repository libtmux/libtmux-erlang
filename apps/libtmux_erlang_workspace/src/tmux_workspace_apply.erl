-module(tmux_workspace_apply).
-moduledoc """
Execute the exact operations in a validated workspace plan.

`run/3` verifies the source digest, endpoint observation and ownership before
dispatch. Each step checks captured preconditions again. Drift stops execution
with plan_conflict and a completed prefix; an uncertain mutation is never
retried. This is not atomic compare-and-apply or automatic rollback.

The caller owns in-flight core operations. A cancel reference accepts
{tmux_workspace_cancel, Ref}; cancellation before dispatch is distinguished
from cancellation after possible delivery. Results keep native command outcome
and cleanup separate from workspace postconditions. Failed creation can leave
untagged resources; inspect its reported IDs before explicit recovery.
""".
-export([run/3]).
-export_type([options/0, receipt/0]).

-doc "Shell host policy, cancellation reference and optional progress recipient. No callback or module is selected from a plan.".
-type options() :: #{allow_shell => boolean(), cancel => reference(), progress => pid()}.
-doc "Execution status and verified step prefix. operation_outcome describes the current native command, not reversal of earlier steps.".
-type receipt() :: #{completed := [map()], plan_hash := binary(),
    bindings => map(), code => atom(), step => non_neg_integer(),
    operation_outcome => tmux_operation:outcome(), cleanup => tmux_operation:cleanup(),
    atom() => term()}.

-doc """
Read the referenced desired file and execute this plan through one-shot core
operations. Performs file and tmux I/O. allow_shell defaults false and must
permit any recorded shell opt-in. The endpoint belongs to the caller and is
left open. Returns verified receipts or a failure with its completed prefix.

Names and launch intent come only from the hash-checked desired document.
Plan data cannot carry arbitrary tmux commands. Progress messages are
{tmux_workspace_step, CancelRef, Number, Operation}; they contain no launch
arguments. Closing the caller's endpoint remains its responsibility.
""".
-spec run(tmux_workspace_plan:t(), tmux_server:t(), options()) ->
    {ok, receipt()} | {error, receipt()}.
run(Plan, Server, Options) ->
    Map = tmux_workspace_plan:to_map(Plan),
    Base = #{completed => [], plan_hash => maps:get(<<"planHash">>, Map)},
    try
        valid_options(Options),
        _ = unwrap(tmux_workspace_plan:from_map(Map)),
        Workspace = unwrap(tmux_workspace:load(maps:get(<<"source">>, Map))),
        Document = tmux_workspace:to_map(Workspace),
        tmux_workspace_plan:validate_desired(Map, Document),
        validate_execution(Map, Document, Options),
        Nodes = maps:from_list([{maps:get(key, N), N}
            || N <- tmux_workspace_state:desired_nodes(Document)]),
        loop(maps:get(<<"steps">>, Map), 1, Document, Nodes, Map, Server,
            maps:get(<<"before">>, Map), maps:get(<<"bindings">>, Map),
            Options, Base)
    catch throw:{workspace_error, Detail} -> {error, maps:merge(Base, Detail)} end.

loop([], _Number, Document, Nodes, _Map, Server, Expected, Bindings, Options, Receipt) ->
    try
        Current = tmux_workspace_state:observe(Server, Options),
        same(Expected, Current),
        verify_final(Document, Nodes, Bindings, Current),
        {ok, Receipt#{bindings => Bindings}}
    catch throw:{workspace_error, Detail} ->
        {error, maps:merge(Receipt#{bindings => Bindings}, Detail)}
    end;
loop([Step | Rest], Number, Document, Nodes, Map, Server,
     Expected, Bindings, Options, Receipt) ->
    try
        Before = tmux_workspace_state:observe(Server, Options),
        same(Expected, Before),
        tmux_workspace_state:checkpoint(Options),
        notify(Options, Number, maps:get(<<"op">>, Step)),
        Command = command(Step, Nodes, Bindings, Before, Document),
        case execute(Server, Command, Options) of
            {error, Error} ->
                {error, maps:merge(Receipt#{bindings => Bindings, step => Number}, Error)};
            {ok, Result, Cancelled} ->
                try
                    NextBindings = created_bindings(Step, Result, Bindings),
                    After = tmux_workspace_state:observe(Server,
                        maps:remove(cancel, Options)),
                    verify_change(Step, Before, After, Bindings,
                        NextBindings, Nodes, Document),
                    Done = #{number => Number, operation => maps:get(<<"op">>, Step),
                        target => maps:get(<<"key">>, Step,
                            maps:get(<<"target">>, Step, null))},
                    Next = Receipt#{completed => maps:get(completed, Receipt) ++ [Done],
                        bindings => NextBindings},
                    case Cancelled of
                        true -> {error, Next#{code => cancelled, step => Number,
                            operation_outcome => success, cleanup => complete}};
                        false -> loop(Rest, Number + 1, Document, Nodes, Map, Server,
                            After, NextBindings, Options, Next)
                    end
                catch throw:{workspace_error, Detail} ->
                    Reported = try created_bindings(Step, Result, Bindings)
                        catch throw:{workspace_error, _} -> Bindings end,
                    {error, maps:merge(Receipt#{step => Number, bindings => Bindings,
                        reported_bindings => Reported,
                        operation_outcome => success, cleanup => complete}, Detail)}
                end
        end
    catch throw:{workspace_error, Failure} ->
        Outcome = case maps:get(code, Failure) of
            cancelled -> cancelled_before_send;
            _ -> not_started
        end,
        {error, maps:merge(Receipt#{step => Number, bindings => Bindings,
            operation_outcome => Outcome, cleanup => complete}, Failure)}
    end.

execute(Server, Command, Options) ->
    tmux_workspace_state:checkpoint(Options),
    case tmux_operation:start(Server, Command, #{deadline_ms => 2000}) of
        {error, Error} -> {error, command_error(Error)};
        {ok, Operation} ->
            Parent = self(), Tag = make_ref(),
            {Waiter, Monitor} = spawn_monitor(fun() ->
                Parent ! {Tag, tmux_operation:await(Operation, 3000)}
            end),
            try wait(Operation, Tag, Monitor, Options, false)
            after
                _ = tmux_operation:cancel(Operation),
                erlang:demonitor(Monitor, [flush]),
                exit(Waiter, shutdown)
            end
    end.

wait(Operation, Tag, Monitor, Options, Cancelled) ->
    Cancel = maps:get(cancel, Options, none),
    receive
        {Tag, {ok, Result}} -> {ok, Result, Cancelled};
        {Tag, {error, Error}} ->
            Detail = command_error(Error),
            {error, case Cancelled of true -> Detail#{code => cancelled}; false -> Detail end};
        {tmux_workspace_cancel, Cancel} when is_reference(Cancel) ->
            _ = tmux_operation:cancel(Operation),
            wait(Operation, Tag, Monitor, maps:remove(cancel, Options), true);
        {'DOWN', Monitor, process, _, _} ->
            _ = tmux_operation:cancel(Operation),
            {error, #{code => waiter_failed, operation_outcome => unknown,
                      cleanup => unverified}}
    after 4000 ->
        _ = tmux_operation:cancel(Operation),
        {error, #{code => operation_timeout, operation_outcome => unknown,
                  cleanup => unverified}}
    end.

command_error(Error) ->
    (maps:with([code, cleanup, phase, mutation, stream, errno], Error))#{
        operation_outcome => maps:get(outcome, Error, unknown)}.

command(#{<<"op">> := <<"create_session">>, <<"key">> := K,
          <<"window">> := WK, <<"pane">> := PK}, Nodes, _, _, _) ->
    S = maps:get(K, Nodes), W = maps:get(WK, Nodes), P = maps:get(PK, Nodes),
    raw(<<"new-session">>, [<<"-d">>, <<"-P">>, <<"-F">>,
        <<"#{session_id}\t#{window_id}\t#{pane_id}">>,
        <<"-s">>, literal(maps:get(name, S)), <<"-n">>, literal(maps:get(name, W))]
        ++ launch(P));
command(#{<<"op">> := <<"create_window">>, <<"key">> := K,
          <<"parent">> := SK, <<"pane">> := PK}, Nodes, Bindings, State, _) ->
    W = maps:get(K, Nodes), P = maps:get(PK, Nodes),
    Session = tmux_workspace_state:resource(maps:get(SK, Bindings), State),
    Id = maps:get(<<"id">>, Session),
    Index = 1 + lists:max([maps:get(<<"index">>, L)
        || L <- maps:get(<<"links">>, State), maps:get(<<"session">>, L) =:= Id]),
    raw(<<"new-window">>, [<<"-d">>, <<"-P">>, <<"-F">>,
        <<"#{window_id}\t#{pane_id}">>, <<"-t">>,
        <<Id/binary, $:, (integer_to_binary(Index))/binary>>,
        <<"-n">>, literal(maps:get(name, W))] ++ launch(P));
command(#{<<"op">> := <<"create_pane">>, <<"key">> := K,
          <<"anchor">> := Anchor}, Nodes, Bindings, State, _) ->
    Ref = anchor(Anchor, Bindings),
    P = maps:get(K, Nodes),
    raw(<<"split-window">>, [<<"-d">>, <<"-P">>, <<"-F">>, <<"#{pane_id}">>,
        <<"-t">>, native_target(tmux_workspace_state:resource(Ref, State))] ++ launch(P));
command(#{<<"op">> := <<"remove">>, <<"target">> := Ref}, _, _, State, Document) ->
    R = tmux_workspace_state:resource(Ref, State),
    tmux_workspace_plan:removable(R, Document, State),
    Name = case maps:get(<<"kind">>, R) of
        <<"session">> -> <<"kill-session">>;
        <<"window">> -> <<"kill-window">>;
        <<"pane">> -> <<"kill-pane">>
    end,
    raw(Name, [<<"-t">>, native_target(R)]);
command(#{<<"op">> := Op, <<"key">> := K, <<"with">> := Other},
        _, Bindings, State, _) when Op =:= <<"swap_panes">>; Op =:= <<"swap_windows">> ->
    Name = case Op of <<"swap_panes">> -> <<"swap-pane">>;
        <<"swap_windows">> -> <<"swap-window">> end,
    raw(Name, [<<"-d">>, <<"-s">>, target(K, Bindings, State),
        <<"-t">>, target(Other, Bindings, State)]);
command(#{<<"op">> := Op, <<"key">> := K}, Nodes, Bindings, State, Document) ->
    N = maps:get(K, Nodes), R = tmux_workspace_state:resource(maps:get(K, Bindings), State),
    Target = native_target(R),
    case Op of
        <<"rename">> ->
            Name = case maps:get(kind, N) of <<"session">> -> <<"rename-session">>;
                <<"window">> -> <<"rename-window">> end,
            raw(Name, [<<"-t">>, Target, <<"--">>, literal(maps:get(name, N))]);
        <<"respawn">> -> raw(<<"respawn-pane">>,
            [<<"-k">>, <<"-t">>, Target] ++ launch(N));
        <<"layout">> -> raw(<<"select-layout">>,
            [<<"-t">>, Target, <<"--">>, maps:get(layout, N)]);
        <<"stamp">> ->
            Tag = tmux_workspace_state:tag(Document, N, Bindings, State),
            Scope = case maps:get(kind, N) of
                <<"session">> -> []; <<"window">> -> [<<"-w">>];
                <<"pane">> -> [<<"-p">>]
            end,
            raw(<<"set-option">>, Scope ++ [<<"-t">>, Target, <<"--">>,
                <<"@libtmux_workspace">>, tmux_workspace_wire:encode(Tag)])
    end.

launch(Node) ->
    [<<"-c">>, literal(maps:get(cwd, Node)), <<"--">> |
        unwrap(tmux_command:launch(maps:get(launch, Node)))].
literal(Value) -> unwrap(tmux_command:literal_format(Value)).
raw(Name, Args) -> unwrap(tmux_command:raw(Name, Args)).
target(K, Bindings, State) ->
    native_target(tmux_workspace_state:resource(maps:get(K, Bindings), State)).
native_target(#{<<"kind">> := <<"session">>, <<"id">> := Id}) -> <<Id/binary, $:>>;
native_target(#{<<"id">> := Id}) -> Id.
anchor(#{<<"key">> := Key}, Bindings) -> maps:get(Key, Bindings);
anchor(#{<<"target">> := Ref}, _) -> Ref.

created_bindings(Step, #{stdout := Output}, Bindings) ->
    Fields = case maps:get(<<"op">>, Step) of
        <<"create_session">> -> [{<<"key">>, <<"session">>},
            {<<"window">>, <<"window">>}, {<<"pane">>, <<"pane">>}];
        <<"create_window">> -> [{<<"key">>, <<"window">>}, {<<"pane">>, <<"pane">>}];
        <<"create_pane">> -> [{<<"key">>, <<"pane">>}];
        _ -> []
    end,
    case Fields of
        [] -> Bindings;
        _ ->
            Values = binary:split(string:trim(Output, trailing, [10]), <<"\t">>, [global]),
            ensure(length(Values) =:= length(Fields), postcondition_failed),
            lists:foldl(fun({{Field, Kind}, Id}, Acc) ->
                tmux_workspace_state:id(Kind, Id),
                Acc#{maps:get(Field, Step) => tmux_workspace_state:ref(Kind, Id)}
            end, Bindings, lists:zip(Fields, Values))
    end.

verify_change(Step, Before, After, Bindings, NextBindings, Nodes, Document) ->
    ensure(maps:get(<<"instance">>, Before) =:= maps:get(<<"instance">>, After),
        server_changed),
    Op = maps:get(<<"op">>, Step),
    OldRows = maps:from_list([{tmux_workspace_state:ref(R), R}
        || R <- maps:get(<<"resources">>, Before)]),
    NewRows = maps:from_list([{tmux_workspace_state:ref(R), R}
        || R <- maps:get(<<"resources">>, After)]),
    Created = [Ref || {K, Ref} <- maps:to_list(NextBindings), not maps:is_key(K, Bindings)],
    Removed = case Op of
        <<"remove">> -> subtree(maps:get(<<"target">>, Step), Before);
        _ -> []
    end,
    ensure(lists:all(fun(Ref) -> maps:is_key(Ref, NewRows) end, Created),
        creation_not_observed),
    ensure(lists:sort(maps:keys(NewRows) -- maps:keys(OldRows)) =:= lists:sort(Created)
        andalso lists:sort(maps:keys(OldRows) -- maps:keys(NewRows)) =:= lists:sort(Removed),
        topology_changed),
    Touched = case maps:find(<<"key">>, Step) of
        {ok, K} -> maps:get(K, NextBindings);
        error -> maps:get(<<"target">>, Step)
    end,
    Swapped = case Op of
        <<"swap_panes">> -> [Touched, maps:get(maps:get(<<"with">>, Step), Bindings)];
        _ -> []
    end,
    AffectedWindows = affected_windows(Created ++ Removed ++ Swapped, Before, After),
    maps:foreach(fun(Ref, Old) ->
        case maps:find(Ref, NewRows) of
            error -> ok;
            {ok, New} ->
                Ignore = case {Ref =:= Touched, Op} of
                    {true, <<"rename">>} -> [<<"name">>];
                    {true, <<"stamp">>} -> [<<"tag">>];
                    {true, <<"layout">>} -> [<<"layout">>];
                    _ -> []
                end,
                Geometry = case lists:member(Ref, AffectedWindows) of
                    true -> [<<"layout">>];
                    false -> case maps:get(<<"parent">>, Old) of
                        Parent when is_binary(Parent) ->
                            case lists:member(tmux_workspace_state:ref(<<"window">>, Parent),
                                    AffectedWindows) of true -> [<<"index">>]; false -> [] end;
                        _ -> []
                    end
                end,
                ensure(maps:without(Ignore ++ Geometry, Old) =:=
                    maps:without(Ignore ++ Geometry, New), observed_drift)
        end
    end, OldRows),
    AllowedLinkWindows = [maps:get(<<"id">>, R) || Ref <- Created ++ Removed,
        R <- [case maps:find(Ref, NewRows) of
            {ok, Value} -> Value; error -> maps:get(Ref, OldRows) end],
        maps:get(<<"kind">>, R) =:= <<"window">>],
    verify_links(Step, Before, After, Bindings, AllowedLinkWindows, Removed),
    lists:foreach(fun({K, Ref}) ->
        case maps:is_key(K, Bindings) of
            true -> ok;
            false ->
                N = maps:get(K, Nodes), R = maps:get(Ref, NewRows),
                case maps:get(parent, N) of
                    null -> ok;
                    PK ->
                        Parent = maps:get(maps:get(PK, NextBindings), NewRows),
                        ensure(lists:member(R, tmux_workspace_state:children(Parent, After)),
                            postcondition_failed)
                end
        end
    end, maps:to_list(NextBindings)),
    case Op of
        <<"rename">> -> ensure(maps:get(<<"name">>, maps:get(Touched, NewRows)) =:=
            maps:get(name, maps:get(maps:get(<<"key">>, Step), Nodes)), postcondition_failed);
        <<"stamp">> -> ensure(maps:get(<<"tag">>, maps:get(Touched, NewRows)) =:=
            tmux_workspace_state:tag(Document,
                maps:get(maps:get(<<"key">>, Step), Nodes), NextBindings, Before),
            postcondition_failed);
        <<"swap_panes">> ->
            [A, B] = Swapped,
            ensure(maps:get(<<"index">>, maps:get(A, OldRows)) =:=
                maps:get(<<"index">>, maps:get(B, NewRows)) andalso
                maps:get(<<"index">>, maps:get(B, OldRows)) =:=
                maps:get(<<"index">>, maps:get(A, NewRows)), postcondition_failed);
        _ -> ok
    end.

verify_links(Step, Before, After, Bindings, ChangedWindows, Removed) ->
    Old = maps:get(<<"links">>, Before),
    Expected = case maps:get(<<"op">>, Step) of
        <<"swap_windows">> ->
            A = tmux_workspace_state:resource(maps:get(maps:get(<<"key">>, Step), Bindings), Before),
            B = tmux_workspace_state:resource(maps:get(maps:get(<<"with">>, Step), Bindings), Before),
            AI = maps:get(<<"id">>, A), BI = maps:get(<<"id">>, B),
            [LA] = [L || L <- Old, maps:get(<<"window">>, L) =:= AI],
            [LB] = [L || L <- Old, maps:get(<<"window">>, L) =:= BI],
            [case L of
                LA -> L#{<<"index">> => maps:get(<<"index">>, LB)};
                LB -> L#{<<"index">> => maps:get(<<"index">>, LA)};
                _ -> L
            end || L <- Old];
        _ -> Old
    end,
    Renumbered = [maps:get(<<"session">>, L) || L <- Old,
        lists:member(tmux_workspace_state:ref(<<"window">>, maps:get(<<"window">>, L)), Removed)],
    Keep = fun(Links) -> lists:sort([case lists:member(maps:get(<<"session">>, L), Renumbered) of
        true -> maps:remove(<<"index">>, L);
        false -> L
    end || L <- Links, not lists:member(maps:get(<<"window">>, L), ChangedWindows)]) end,
    ensure(Keep(Expected) =:= Keep(maps:get(<<"links">>, After)), membership_changed).

affected_windows(Refs, Before, After) ->
    lists:usort(lists:append([case R of
        #{<<"kind">> := <<"window">>} -> [tmux_workspace_state:ref(R)];
        #{<<"kind">> := <<"pane">>, <<"parent">> := P} ->
            [tmux_workspace_state:ref(<<"window">>, P)];
        _ -> []
    end || S <- [Before, After], R <- maps:get(<<"resources">>, S),
        lists:member(tmux_workspace_state:ref(R), Refs)])).

subtree(Ref, State) ->
    R = tmux_workspace_state:resource(Ref, State),
    [Ref | lists:append([subtree(tmux_workspace_state:ref(C), State)
        || C <- tmux_workspace_state:children(R, State)])].

verify_final(Document, Nodes, Bindings, State) ->
    Owned = tmux_workspace_plan:owned(Document, State),
    ensure(lists:sort(maps:keys(Owned)) =:= lists:sort(maps:keys(Nodes)),
        incomplete_workspace),
    maps:foreach(fun(Key, N) ->
        R = tmux_workspace_state:resource(maps:get(Key, Bindings), State),
        ensure(maps:get(<<"tag">>, R) =:=
            tmux_workspace_state:tag(Document, N, Bindings, State), postcondition_failed),
        case maps:find(name, N) of
            {ok, Name} -> ensure(maps:get(<<"name">>, R) =:= Name, postcondition_failed);
            error -> ok
        end,
        Desired = [maps:get(CK, Bindings)
            || #{key := CK, parent := PK} <- tmux_workspace_state:desired_nodes(Document),
               PK =:= Key],
        Actual = [tmux_workspace_state:ref(C) || C <- tmux_workspace_state:children(R, State),
            lists:member(tmux_workspace_state:ref(C), Desired)],
        ensure(Desired =:= Actual, postcondition_failed)
    end, Nodes).

validate_execution(Map, Document, Options) ->
    Nodes = maps:from_list([{maps:get(key, N), N}
        || N <- tmux_workspace_state:desired_nodes(Document)]),
    HasShell = lists:any(fun(N) -> maps:is_key(launch, N) andalso
        maps:is_key(shell, maps:get(launch, N)) end, maps:values(Nodes)),
    ensure(not HasShell orelse (maps:get(<<"allowShell">>, Map)
        andalso maps:get(allow_shell, Options, false)), shell_not_allowed),
    %% Validate compiler output against the stored observation. Fresh tmux state
    %% can reject this plan; it never supplies replacement operations.
    Expected = unwrap(tmux_workspace_plan:from_state(maps:get(<<"source">>, Map),
        Document, maps:get(<<"before">>, Map),
        #{adopt => maps:get(<<"adopt">>, Map),
          allow_shell => maps:get(<<"allowShell">>, Map)})),
    ensure(tmux_workspace_plan:to_map(Expected) =:= Map, invalid_plan).

same(Expected, Current) -> ensure(Expected =:= Current, observed_drift).
valid_options(Options) when is_map(Options) ->
    ensure(maps:without([allow_shell, cancel, progress], Options) =:= #{}, invalid_options),
    ensure(is_boolean(maps:get(allow_shell, Options, false)), invalid_options),
    ensure(not maps:is_key(cancel, Options) orelse is_reference(maps:get(cancel, Options)),
        invalid_options),
    ensure(not maps:is_key(progress, Options) orelse is_pid(maps:get(progress, Options)),
        invalid_options);
valid_options(_) -> tmux_workspace_wire:fail(invalid_options, []).

notify(Options, Number, Op) ->
    case maps:find(progress, Options) of
        {ok, Pid} -> Pid ! {tmux_workspace_step,
            maps:get(cancel, Options, none), Number, Op}, ok;
        error -> ok
    end.
unwrap({ok, Value}) -> Value;
unwrap({error, Detail}) -> throw({workspace_error, Detail}).
ensure(true, _) -> ok;
ensure(false, Reason) ->
    case lists:member(Reason, [observed_drift, server_changed, topology_changed,
            membership_changed, postcondition_failed, incomplete_workspace]) of
        true -> tmux_workspace_state:conflict(Reason, null);
        false -> tmux_workspace_wire:fail(Reason, [])
    end.
