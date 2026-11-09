-module(tmux_workspace_plan).
-moduledoc """
Build a workspace reconciliation plan without changing tmux.

`new/3` loads desired JSON, captures tmux and reads local ownership tags through
the public core API. Plans retain stable IDs and a server-incarnation key.
They contain hashes and a source-file reference rather than launch arguments.
`from_map/1` validates the versioned plan before `tmux_workspace_apply:run/3`.
Captures are observations across commands, not atomic reservations.

Untagged session/window names conflict unless their resource keys are listed
in the adopt option. Pane adoption uses its ordered position within that
window and always plans a respawn to establish launch intent. Ownership tags
and parent manifests must agree; missing or edited metadata is a conflict.
Plans never infer an original launch from a pane's current command.

Pane creation schedules fixed targets from the saved tiled layout, balancing
splits before applying the requested arrangement. `tmux_workspace_apply:run/3`
chooses the longest usable cell axis at each checked step. New windows use a
breadth-first target schedule until their geometry can be observed. Available
area and tmux options can still reject a split; this is geometric scheduling,
not a guarantee that every requested pane count fits.
""".
-export([new/3, to_map/1, from_map/1, read/1, write/2, schema/0]).
-export([from_state/4, owned/2, removable/3, validate_desired/2]).
-export_type([t/0, options/0]).

-doc "A validated, versioned plan value. Use `to_map/1` for JSON data.".
-opaque t() :: {workspace_plan, map()}.
-doc "Explicit adoption keys and shell policy; cancel is an application-owned cancellation reference.".
-type options() :: #{adopt => [binary()], allow_shell => boolean(), cancel => reference()}.

-doc """
Load the source file and observe an existing endpoint, returning an inert plan.
Performs file and read-only tmux I/O. allow_shell defaults false; adopt defaults
empty. Conflicting ownership returns plan_conflict. No resource is adopted or
changed until `tmux_workspace_apply:run/3` executes the stored operations.
""".
-spec new(file:filename_all(), tmux_server:t(), options()) ->
    {ok, t()} | {error, map()}.
new(Source, Server, Options) ->
    guarded(fun() ->
        validate_options(Options),
        Workspace = unwrap(tmux_workspace:load(Source)),
        Document = tmux_workspace:to_map(Workspace),
        policy(Document, Options),
        State = tmux_workspace_state:observe(Server, Options),
        build(unicode:characters_to_binary(filename:absname(Source)),
              Document, State, Options)
    end).

-doc "Return JSON-ready data, without I/O. Source paths and observed names remain in the plan.".
-spec to_map(t()) -> map().
to_map({workspace_plan, Map}) -> Map.

-doc "Validate a JSON-ready plan, including its schema and content digests, without I/O.".
-spec from_map(map()) -> {ok, t()} | {error, map()}.
from_map(Map) -> guarded(fun() -> validate(Map), {workspace_plan, Map} end).

-doc "Read a bounded regular JSON plan file and validate it before use. Performs file I/O.".
-spec read(file:filename_all()) -> {ok, t()} | {error, map()}.
read(Path) -> guarded(fun() ->
    Map = tmux_workspace_wire:read(Path), validate(Map), {workspace_plan, Map}
end).

-doc "Atomically replace a plan file with canonical JSON and mode 0600. Performs file I/O.".
-spec write(t(), file:filename_all()) -> ok | {error, map()}.
write({workspace_plan, Map}, Path) ->
    case guarded(fun() -> validate(Map), tmux_workspace_wire:write(Path, Map) end) of
        {ok, ok} -> ok;
        {error, _} = Error -> Error
    end.

-doc "Return versioned field/operation declarations and resource bounds, without I/O.".
-spec schema() -> map().
schema() ->
    #{<<"version">> => 1, <<"ownershipVersion">> => 1,
      <<"documentBytes">> => 262144, <<"maxSteps">> => 4096,
      <<"paneScheduling">> => <<"saved_tiled_cells_v1">>,
      <<"fields">> => [<<"version">>, <<"schemaDigest">>, <<"planHash">>,
          <<"desiredHash">>, <<"observedHash">>, <<"source">>, <<"endpoint">>,
          <<"workspace">>, <<"before">>, <<"bindings">>, <<"adopt">>,
          <<"allowShell">>, <<"steps">>],
      <<"operations">> => #{
          <<"create_session">> => [<<"op">>, <<"key">>, <<"window">>, <<"pane">>],
          <<"create_window">> => [<<"op">>, <<"key">>, <<"parent">>, <<"pane">>],
          <<"create_pane">> => [<<"op">>, <<"key">>, <<"parent">>, <<"anchor">>, <<"axis">>],
          <<"swap_panes">> => [<<"op">>, <<"key">>, <<"with">>],
          <<"swap_windows">> => [<<"op">>, <<"key">>, <<"with">>],
          <<"rename">> => [<<"op">>, <<"key">>],
          <<"respawn">> => [<<"op">>, <<"key">>],
          <<"layout">> => [<<"op">>, <<"key">>],
          <<"stamp">> => [<<"op">>, <<"key">>],
          <<"remove">> => [<<"op">>, <<"target">>]}}.

-doc false.
-spec from_state(binary(), map(), map(), map()) -> {ok, t()} | {error, map()}.
from_state(Source, Document, State, Options) -> guarded(fun() ->
    validate_options(Options), policy(Document, Options),
    build(Source, Document, State, Options)
end).

build(Source, Document, State, Options) ->
    _ = tmux_workspace_state:validate(State),
    Nodes = tmux_workspace_state:desired_nodes(Document),
    Keys = [maps:get(key, N) || N <- Nodes],
    Names = [{maps:get(kind, N), maps:get(parent, N), maps:get(name, N)}
        || N <- Nodes, maps:is_key(name, N)],
    ensure(length(Names) =:= length(lists:usort(Names)), ambiguous_desired_name),
    ensure(lists:all(fun(K) -> lists:member(K, Keys) end,
        maps:get(adopt, Options, [])), unknown_adoption_key),
    Owned = owned(Document, State),
    Initial = #{bindings => #{}, created => #{}, anchors => #{}, steps => [],
        owned => Owned, state => State, options => Options},
    Matched = lists:foldl(fun match/2, Initial, Nodes),
    Bindings = maps:get(bindings, Matched),
    Created = maps:get(created, Matched),
    Removed = [R || {K, R} <- lists:sort(maps:to_list(Owned)), not lists:member(K, Keys)],
    Roots = [R || R <- Removed, not lists:any(fun(Parent) ->
        lists:member(R, descendants(Parent, State))
    end, Removed -- [R])],
    Deletes = [begin removable(R, Document, State),
        #{<<"op">> => <<"remove">>, <<"target">> => tmux_workspace_state:ref(R)}
        end || R <- Roots],
    Creations = lists:reverse(maps:get(steps, Matched)),
    Swaps = reorder(Nodes, Bindings, State, Creations),
    ChangedParents = [maps:get(parent, N) || N <- Nodes,
        maps:is_key(maps:get(key, N), Created)] ++
        [maps:get(parent, N) || Step <- Swaps, N <- Nodes,
            maps:get(key, N) =:= maps:get(<<"key">>, Step)],
    Layouts = [#{<<"op">> => <<"layout">>, <<"key">> => maps:get(key, N)}
        || N <- Nodes, maps:is_key(layout, N),
            needs_layout(N, Bindings, Created, State, Removed, ChangedParents)],
    Stamps = [#{<<"op">> => <<"stamp">>, <<"key">> => maps:get(key, N)}
        || N <- lists:reverse(Nodes), needs_stamp(N, Document, Bindings,
            Created, State, Layouts)],
    Steps = Creations ++ Deletes ++ Swaps ++ Layouts ++ Stamps,
    Base = #{<<"version">> => 1, <<"schemaDigest">> => tmux_workspace_wire:digest(schema()),
        <<"source">> => Source, <<"endpoint">> => maps:get(endpoint, Document),
        <<"workspace">> => maps:get(id, Document),
        <<"desiredHash">> => tmux_workspace_wire:digest(Document),
        <<"observedHash">> => tmux_workspace_wire:digest(State),
        <<"before">> => State, <<"bindings">> => Bindings,
        <<"adopt">> => maps:get(adopt, Options, []),
        <<"allowShell">> => maps:get(allow_shell, Options, false), <<"steps">> => Steps},
    Map = Base#{<<"planHash">> => tmux_workspace_wire:digest(Base)},
    validate(Map),
    {workspace_plan, Map}.

match(#{key := Key, parent := Parent, kind := Kind} = Node, Acc) ->
    #{owned := Owned, created := Created, bindings := Bindings,
      state := State, options := Options} = Acc,
    case maps:find(Key, Owned) of
        {ok, R} ->
            ensure(maps:get(<<"kind">>, R) =:= Kind, invalid_ownership),
            expected_parent(R, Parent, Bindings, State),
            changes(Node, R, bind(Key, R, Acc));
        error ->
            case maps:is_key(Key, Created) of
                true -> Acc;
                false ->
                    Candidates = candidates(Node, Bindings, State),
                    case Candidates of
                        [] -> create(Node, Acc);
                        [R] ->
                            CanAdopt = lists:member(Key, maps:get(adopt, Options, []))
                                andalso maps:get(<<"tag">>, R) =:= null,
                            case {CanAdopt, Kind} of
                                {true, _} -> changes(Node, R, bind(Key, R, Acc));
                                {false, <<"pane">>} -> create(Node, Acc);
                                _ -> tmux_workspace_state:conflict(name_in_use, Key)
                            end;
                        _ -> tmux_workspace_state:conflict(ambiguous_match, Key)
                    end
            end
    end.

bind(Key, R, #{bindings := Bindings, state := State} = Acc) ->
    case maps:get(<<"kind">>, R) of
        <<"window">> -> ensure(length([L || L <- maps:get(<<"links">>, State),
            maps:get(<<"window">>, L) =:= maps:get(<<"id">>, R)]) =:= 1, shared_window);
        _ -> ok
    end,
    Acc#{bindings => Bindings#{Key => tmux_workspace_state:ref(R)}}.

changes(#{key := Key, kind := Kind} = N, R, Acc) ->
    case Kind of
        <<"pane">> ->
            Old = case maps:get(<<"tag">>, R) of
                null -> null;
                Tag -> maps:get(<<"launch">>, Tag)
            end,
            case Old =:= maps:get(launch_hash, N) of
                true -> Acc;
                false -> add(#{<<"op">> => <<"respawn">>, <<"key">> => Key}, Acc)
            end;
        _ ->
            case maps:get(<<"name">>, R) =:= maps:get(name, N) of
                true -> Acc;
                false -> add(#{<<"op">> => <<"rename">>, <<"key">> => Key}, Acc)
            end
    end.

create(#{key := Key, kind := <<"session">>, windows := [W | _]}, Acc) ->
    #{key := WK, panes := [P | _]} = W,
    PK = maps:get(key, P),
    created([Key, WK, PK], add(#{<<"op">> => <<"create_session">>,
        <<"key">> => Key, <<"window">> => WK, <<"pane">> => PK}, Acc));
create(#{key := Key, kind := <<"window">>, parent := Parent, panes := [P | _]}, Acc) ->
    PK = maps:get(key, P),
    created([Key, PK], add(#{<<"op">> => <<"create_window">>,
        <<"key">> => Key, <<"parent">> => Parent, <<"pane">> => PK}, Acc));
create(#{key := Key, kind := <<"pane">>, parent := Parent}, Acc) ->
    #{bindings := Bindings, state := State, anchors := Anchors} = Acc,
    Queue = case maps:find(Parent, Anchors) of
        {ok, Existing} -> Existing;
        error ->
            Children = tmux_workspace_state:children(tmux_workspace_state:resource(
                maps:get(Parent, Bindings), State), State),
            Window = tmux_workspace_state:resource(maps:get(Parent, Bindings), State),
            Cells = tmux_workspace_layout:cells(maps:get(<<"layout">>, Window)),
            Candidates = [{R, Cell} || R <- Children,
                Cell <- [maps:get(maps:get(<<"id">>, R), Cells, floating)],
                tmux_workspace_layout:split(Cell) =/= none],
            Largest = lists:sort(fun({A, CA}, {B, CB}) ->
                {-area(CA), maps:get(<<"index">>, A)} < {-area(CB), maps:get(<<"index">>, B)}
            end, Candidates),
            [{#{<<"target">> => tmux_workspace_state:ref(R)}, Cell}
                || {R, Cell} <- Largest]
    end,
    ensure(Queue =/= [], pane_capacity_exhausted),
    [{Anchor, Cell} | Rest] = Queue,
    Halves = case Cell of
        unknown -> [{Anchor, unknown}, {#{<<"key">> => Key}, unknown}];
        _ ->
            {_, Old, New} = tmux_workspace_layout:split(Cell),
            [{A, C} || {A, C} <- [{Anchor, Old}, {#{<<"key">> => Key}, New}],
                tmux_workspace_layout:split(C) =/= none]
    end,
    Next = Acc#{anchors => Anchors#{Parent => Rest ++ Halves}},
    created([Key], add(#{<<"op">> => <<"create_pane">>, <<"key">> => Key,
        <<"parent">> => Parent, <<"anchor">> => Anchor,
        <<"axis">> => <<"longest_available">>}, Next)).

area({Width, Height}) -> Width * Height.

created(_Keys, #{created := Created, anchors := Anchors, steps := [Step | _]} = Acc) ->
    Key = maps:get(<<"key">>, Step),
    Pairs = case maps:get(<<"op">>, Step) of
        <<"create_session">> ->
            WK = maps:get(<<"window">>, Step),
            [{Key, <<"session">>, null}, {WK, <<"window">>, Key},
             {maps:get(<<"pane">>, Step), <<"pane">>, WK}];
        <<"create_window">> ->
            [{Key, <<"window">>, maps:get(<<"parent">>, Step)},
             {maps:get(<<"pane">>, Step), <<"pane">>, Key}];
        _ -> [{Key, <<"pane">>, maps:get(<<"parent">>, Step)}]
    end,
    Queues = case maps:get(<<"op">>, Step) of
        <<"create_pane">> -> Anchors;
        _ -> lists:foldl(fun
            ({K, <<"pane">>, Parent}, M) -> M#{Parent => [{#{<<"key">> => K}, unknown}]};
            (_, M) -> M
        end, Anchors, Pairs)
    end,
    Acc#{anchors => Queues, created => lists:foldl(fun({K, Kind, Parent}, M) ->
        M#{K => #{parent => Parent, kind => Kind}}
    end, Created, Pairs)}.

add(Step, #{steps := Steps} = Acc) -> Acc#{steps => [Step | Steps]}.

reorder(Nodes, Bindings, State, Steps) ->
    Reverse = maps:from_list([{Ref, K} || {K, Ref} <- maps:to_list(Bindings)]),
    Initial = maps:from_list([{maps:get(key, N), case maps:find(maps:get(key, N), Bindings) of
        error -> [];
        {ok, Ref} -> [order_symbol(tmux_workspace_state:ref(R), Reverse)
            || R <- tmux_workspace_state:children(tmux_workspace_state:resource(Ref, State), State)]
    end} || N <- Nodes, maps:get(kind, N) =/= <<"pane">>]),
    Orders = lists:foldl(fun(Step, Acc) ->
        case Step of
            #{<<"op">> := <<"create_session">>, <<"key">> := K,
              <<"window">> := WK, <<"pane">> := PK} ->
                Acc#{K => [{key, WK}], WK => [{key, PK}]};
            #{<<"op">> := <<"create_window">>, <<"key">> := K,
              <<"parent">> := Parent, <<"pane">> := PK} ->
                Acc#{Parent => maps:get(Parent, Acc) ++ [{key, K}], K => [{key, PK}]};
            #{<<"op">> := <<"create_pane">>, <<"key">> := K,
              <<"parent">> := Parent, <<"anchor">> := Anchor} ->
                A = case Anchor of
                    #{<<"key">> := AK} -> {key, AK};
                    #{<<"target">> := Ref} -> order_symbol(Ref, Reverse)
                end,
                Acc#{Parent => insert_after(A, {key, K}, maps:get(Parent, Acc))};
            _ -> Acc
        end
    end, Initial, Steps),
    lists:append([begin
        Parent = maps:get(key, N),
        Desired = [maps:get(key, C) || C <- Nodes, maps:get(parent, C) =:= Parent],
        Current = [K || {key, K} <- maps:get(Parent, Orders)],
        Op = case maps:get(kind, N) of
            <<"session">> -> <<"swap_windows">>;
            <<"window">> -> <<"swap_panes">>
        end,
        swaps(Desired, Current, Op)
    end || N <- Nodes, maps:get(kind, N) =/= <<"pane">>]).

order_symbol(Ref, Reverse) ->
    case maps:find(Ref, Reverse) of {ok, K} -> {key, K}; error -> {target, Ref} end.
insert_after(A, Value, [A | Rest]) -> [A, Value | Rest];
insert_after(A, Value, [H | Rest]) -> [H | insert_after(A, Value, Rest)];
insert_after(_, _, []) -> tmux_workspace_wire:fail(invalid_plan, []).

swaps([], [], _) -> [];
swaps([K | Desired], [K | Current], Op) -> swaps(Desired, Current, Op);
swaps([K | Desired], [Other | Current], Op) ->
    [#{<<"op">> => Op, <<"key">> => K, <<"with">> => Other} |
        swaps(Desired, [case X of K -> Other; _ -> X end || X <- Current], Op)].

candidates(#{kind := <<"session">>, name := Name}, _, State) ->
    [R || R <- maps:get(<<"resources">>, State),
        maps:get(<<"kind">>, R) =:= <<"session">>, maps:get(<<"name">>, R) =:= Name];
candidates(#{kind := <<"window">>, parent := Parent, name := Name}, Bindings, State) ->
    case maps:find(Parent, Bindings) of
        error -> [];
        {ok, Ref} -> [R || R <- tmux_workspace_state:children(
            tmux_workspace_state:resource(Ref, State), State),
            maps:get(<<"name">>, R) =:= Name]
    end;
candidates(#{kind := <<"pane">>, parent := Parent, order := I}, Bindings, State) ->
    case maps:find(Parent, Bindings) of
        error -> [];
        {ok, Ref} ->
            Rows = tmux_workspace_state:children(
                tmux_workspace_state:resource(Ref, State), State),
            case length(Rows) > I of true -> [lists:nth(I + 1, Rows)]; false -> [] end
    end.

expected_parent(R, null, _, _) ->
    ensure(maps:get(<<"kind">>, R) =:= <<"session">>, invalid_ownership);
expected_parent(R, Parent, Bindings, State) ->
    case maps:find(Parent, Bindings) of
        error -> tmux_workspace_state:conflict(parent_changed, Parent);
        {ok, Ref} ->
            P = tmux_workspace_state:resource(Ref, State),
            ensure(lists:member(R, tmux_workspace_state:children(P, State)), parent_changed)
    end.

-doc false.
-spec owned(map(), map()) -> map().
owned(Document, State) ->
    Id = maps:get(id, Document),
    Pairs = [{maps:get(<<"key">>, T), R}
        || #{<<"tag">> := T} = R <- maps:get(<<"resources">>, State),
           is_map(T), maps:get(<<"workspace">>, T) =:= Id],
    ensure(length(Pairs) =:= map_size(maps:from_list(Pairs)), duplicate_ownership),
    Owned = maps:from_list(Pairs),
    maps:foreach(fun(Key, R) ->
        Tag = maps:get(<<"tag">>, R),
        case maps:get(<<"kind">>, R) of
            <<"pane">> -> ensure(is_binary(maps:get(<<"launch">>, Tag)), invalid_ownership);
            _ -> ensure(maps:get(<<"launch">>, Tag) =:= null, invalid_ownership)
        end,
        ensure(maps:get(<<"instance">>, Tag) =:= maps:get(<<"instance">>, State),
            stale_ownership),
        Parent = maps:get(<<"parent">>, Tag),
        case maps:get(<<"kind">>, R) of
            <<"session">> -> ensure(Parent =:= null, invalid_ownership);
            _ ->
                ParentR = case maps:find(Parent, Owned) of
                    {ok, PR} -> PR;
                    error -> tmux_workspace_state:conflict(missing_parent_metadata, Key)
                end,
                ensure(lists:member(R, tmux_workspace_state:children(ParentR, State)),
                    parent_changed)
        end,
        case maps:get(<<"kind">>, R) of
            <<"window">> -> ensure(length([L || L <- maps:get(<<"links">>, State),
                maps:get(<<"window">>, L) =:= maps:get(<<"id">>, R)]) =:= 1,
                shared_window);
            _ -> ok
        end,
        Actual = lists:sort([{CK, maps:get(<<"id">>, CR)} || {CK, CR} <- Pairs,
            maps:get(<<"parent">>, maps:get(<<"tag">>, CR)) =:= Key]),
        Manifest = lists:sort([{maps:get(<<"key">>, C), maps:get(<<"id">>, C)}
            || C <- maps:get(<<"children">>, Tag)]),
        ensure(Manifest =:= Actual, missing_child_metadata)
    end, Owned),
    Owned.

-doc false.
-spec removable(map(), map(), map()) -> ok.
removable(R, Document, State) ->
    lists:foreach(fun(Child) ->
        case maps:get(<<"tag">>, Child) of
            #{<<"workspace">> := Id} when Id =:= map_get(id, Document) -> ok;
            _ -> tmux_workspace_state:conflict(unmanaged_descendant,
                tmux_workspace_state:ref(Child))
        end,
        case maps:get(<<"kind">>, Child) of
            <<"window">> -> ensure(length([L || L <- maps:get(<<"links">>, State),
                maps:get(<<"window">>, L) =:= maps:get(<<"id">>, Child)]) =:= 1,
                shared_window);
            _ -> ok
        end
    end, [R | descendants(R, State)]).

descendants(R, State) ->
    Children = tmux_workspace_state:children(R, State),
    Children ++ lists:append([descendants(C, State) || C <- Children]).

needs_layout(#{key := Key, layout := Name}, Bindings, Created, State, Removed, Parents) ->
    case maps:find(Key, Bindings) of
        error -> true;
        {ok, Ref} ->
            R = tmux_workspace_state:resource(Ref, State),
            Expected = #{<<"name">> => Name,
                <<"hash">> => tmux_workspace_wire:digest(maps:get(<<"layout">>, R))},
            Tag = maps:get(<<"tag">>, R),
            maps:is_key(Key, Created) orelse lists:member(Key, Parents) orelse
                lists:any(fun(X) -> maps:get(<<"parent">>, X) =:= maps:get(<<"id">>, R) end,
                    Removed) orelse Tag =:= null orelse maps:get(<<"layout">>, Tag) =/= Expected
    end.

needs_stamp(#{key := Key} = Node, Document, Bindings, Created, State, Layouts) ->
    case maps:is_key(Key, Created) orelse
         lists:any(fun(S) -> maps:get(<<"key">>, S) =:= Key end, Layouts) of
        true -> true;
        false ->
            Children = [maps:get(key, N) || N <- tmux_workspace_state:desired_nodes(Document),
                maps:get(parent, N) =:= Key],
            case lists:any(fun(K) -> not maps:is_key(K, Bindings) end, Children) of
                true -> true;
                false ->
                    R = tmux_workspace_state:resource(maps:get(Key, Bindings), State),
                    maps:get(<<"tag">>, R) =/= tmux_workspace_state:tag(
                        Document, Node, Bindings, State)
            end
    end.

validate_options(Options) when is_map(Options) ->
    ensure(maps:without([adopt, allow_shell, cancel], Options) =:= #{}, invalid_options),
    ensure(is_boolean(maps:get(allow_shell, Options, false)), invalid_options),
    ensure(not maps:is_key(cancel, Options) orelse is_reference(maps:get(cancel, Options)),
        invalid_options),
    A = maps:get(adopt, Options, []),
    ensure(is_list(A) andalso length(A) =< 2048, invalid_options),
    lists:foreach(fun(K) -> tmux_workspace_wire:text(K, []) end, A),
    ensure(length(A) =:= length(lists:usort(A)), invalid_options);
validate_options(_) -> tmux_workspace_wire:fail(invalid_options, []).

policy(Document, Options) ->
    HasShell = lists:any(fun(N) -> maps:is_key(launch, N) andalso
        maps:is_key(shell, maps:get(launch, N)) end,
        tmux_workspace_state:desired_nodes(Document)),
    case HasShell andalso not maps:get(allow_shell, Options, false) of
        true -> tmux_workspace_wire:fail(shell_not_allowed, []);
        false -> ok
    end.

validate(Map) ->
    Spec = schema(),
    _ = tmux_workspace_wire:fields(Map, maps:get(<<"fields">>, Spec), []),
    ensure(map_size(Map) =:= length(maps:get(<<"fields">>, Spec)), invalid_plan),
    ensure(maps:get(<<"version">>, Map) =:= 1, unsupported_plan_version),
    ensure(maps:get(<<"schemaDigest">>, Map) =:= tmux_workspace_wire:digest(Spec),
        plan_schema_mismatch),
    ensure(maps:get(<<"planHash">>, Map) =:= tmux_workspace_wire:digest(
        maps:remove(<<"planHash">>, Map)), plan_hash_mismatch),
    State = tmux_workspace_state:validate(maps:get(<<"before">>, Map)),
    ensure(maps:get(<<"observedHash">>, Map) =:= tmux_workspace_wire:digest(State),
        invalid_plan),
    lists:foreach(fun(K) -> tmux_workspace_wire:text(maps:get(K, Map), [K]) end,
        [<<"source">>, <<"endpoint">>, <<"workspace">>, <<"desiredHash">>]),
    ensure(filename:pathtype(maps:get(<<"source">>, Map)) =:= absolute, invalid_plan),
    Bindings = maps:get(<<"bindings">>, Map),
    ensure(is_map(Bindings) andalso map_size(Bindings) =< 2048, invalid_plan),
    maps:foreach(fun(K, Ref) ->
        _ = tmux_workspace_wire:text(K, []), tmux_workspace_state:resource(Ref, State)
    end, Bindings),
    Adopt = maps:get(<<"adopt">>, Map),
    ensure(is_list(Adopt) andalso length(Adopt) =< 2048, invalid_plan),
    lists:foreach(fun(K) -> tmux_workspace_wire:text(K, []) end, Adopt),
    ensure(is_boolean(maps:get(<<"allowShell">>, Map)), invalid_plan),
    Steps = maps:get(<<"steps">>, Map),
    ensure(is_list(Steps) andalso length(Steps) =< 4096, plan_limit),
    lists:foreach(fun(Step) ->
        Op = tmux_workspace_wire:require(<<"op">>, Step, []),
        case maps:find(Op, maps:get(<<"operations">>, Spec)) of
            error -> tmux_workspace_wire:fail(unknown_operation, []);
            {ok, Fields} ->
                _ = tmux_workspace_wire:fields(Step, Fields, []),
                ensure(map_size(Step) =:= length(Fields), invalid_plan),
                lists:foreach(fun
                    (<<"anchor">>) ->
                        A = tmux_workspace_wire:fields(maps:get(<<"anchor">>, Step),
                            [<<"key">>, <<"target">>], []),
                        ensure(map_size(A) =:= 1, invalid_plan),
                        [V] = maps:values(A), tmux_workspace_wire:text(V, []);
                    (K) -> tmux_workspace_wire:text(maps:get(K, Step), [])
                end, Fields)
        end
    end, Steps),
    ensure(byte_size(tmux_workspace_wire:encode(Map)) < 262144, plan_limit),
    ok.

-doc false.
-spec validate_desired(map(), map()) -> ok.
validate_desired(Map, Document) ->
    ensure(maps:get(<<"desiredHash">>, Map) =:= tmux_workspace_wire:digest(Document),
        desired_input_changed),
    ensure(maps:get(<<"workspace">>, Map) =:= maps:get(id, Document) andalso
        maps:get(<<"endpoint">>, Map) =:= maps:get(endpoint, Document), invalid_plan).

guarded(Fun) ->
    try {ok, Fun()} catch throw:{workspace_error, Detail} -> {error, Detail} end.
unwrap({ok, Value}) -> Value;
unwrap({error, Detail}) -> throw({workspace_error, Detail}).
ensure(true, _) -> ok;
ensure(false, Reason) ->
    case lists:member(Reason, [invalid_ownership, duplicate_ownership,
            parent_changed, shared_window, stale_ownership, missing_child_metadata]) of
        true -> tmux_workspace_state:conflict(Reason, null);
        false -> tmux_workspace_wire:fail(Reason, [])
    end.
