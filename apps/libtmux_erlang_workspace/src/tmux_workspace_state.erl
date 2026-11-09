-module(tmux_workspace_state).
-moduledoc false.
-export([observe/2, validate/1, resource/2, ref/1, ref/2,
         children/2, desired_nodes/1, tag/4, checkpoint/1, conflict/2, id/2]).
-define(TAG, <<"@libtmux_workspace">>).

-spec observe(tmux_server:t(), map()) -> map().
observe(Server, Options) ->
    checkpoint(Options),
    Snapshot = result(tmux_server:snapshot(Server)),
    #{server_instance := Instance} = tmux_snapshot:metadata(Snapshot),
    Key = result(tmux_identity:fingerprint(Instance)),
    Batches = lists:append([batches(Rows) || Rows <- [
        tmux_snapshot:sessions(Snapshot), tmux_snapshot:windows(Snapshot),
        tmux_snapshot:panes(Snapshot)]]),
    Resources = lists:append(tmux_workspace_reads:map(fun(Rows) ->
        Values = case tmux_option:get_many(Rows, ?TAG, #{}) of
            {ok, Read} -> Read;
            {error, Error} -> throw({workspace_error,
                Error#{cleanup => maps:get(cleanup, Error, unverified)}})
        end,
        [resource_row(Row, Value) || {Row, Value} <- lists:zip(Rows, Values)]
    end, Batches, Options)),
    Links = [#{<<"session">> => tmux_model:get(session_id, L),
               <<"window">> => tmux_model:get(window_id, L),
               <<"index">> => tmux_model:get(index, L)}
        || L <- tmux_snapshot:window_links(Snapshot)],
    #{<<"instance">> => Key, <<"resources">> => Resources, <<"links">> => Links}.

batches([]) -> [];
batches(Rows) ->
    {Batch, Rest} = batch(Rows, 7, []),
    [Batch | batches(Rest)].

batch(Rest, 0, Acc) -> {lists:reverse(Acc), Rest};
batch([], _, Acc) -> {lists:reverse(Acc), []};
batch([Row | Rest], Left, Acc) -> batch(Rest, Left - 1, [Row | Acc]).

resource_row(Row, Value) ->
    Kind = atom_to_binary(tmux_model:entity(Row)),
    Id = tmux_model:get(id, Row),
    Tag = case Value of
        none -> null;
        Bytes when is_binary(Bytes), byte_size(Bytes) =< 32768 ->
            try parse_tag(result(tmux_json:decode(Bytes)), Kind)
            catch throw:{workspace_error, _} ->
                conflict(invalid_metadata, ref(Kind, Id))
            end;
        _ -> conflict(invalid_metadata, ref(Kind, Id))
    end,
    #{<<"kind">> => Kind, <<"id">> => Id, <<"tag">> => Tag,
      <<"name">> => field(name, Row), <<"parent">> => field(window_id, Row),
      <<"index">> => field(index, Row), <<"layout">> => field(layout, Row)}.

field(Name, Row) ->
    Kind = tmux_model:entity(Row),
    case {Name, Kind} of
        {name, pane} -> null;
        {window_id, pane} -> loaded(Name, Row);
        {window_id, _} -> null;
        {index, pane} -> loaded(Name, Row);
        {index, _} -> null;
        {layout, window} -> loaded(Name, Row);
        {layout, _} -> null;
        _ -> loaded(Name, Row)
    end.

loaded(Name, Row) ->
    case tmux_model:get(Name, Row) of
        not_loaded -> tmux_workspace_wire:fail(incomplete_snapshot, [Name]);
        unavailable -> tmux_workspace_wire:fail(unavailable_field, [Name]);
        Value -> Value
    end.

-spec validate(term()) -> map().
validate(Value) ->
    M = tmux_workspace_wire:fields(Value,
        [<<"instance">>, <<"resources">>, <<"links">>], [<<"before">>]),
    Instance = maps:get(<<"instance">>, M, none),
    true_or_fail(is_binary(Instance) andalso byte_size(Instance) =:= 73),
    Resources = maps:get(<<"resources">>, M, none),
    Links = maps:get(<<"links">>, M, none),
    true_or_fail(is_list(Resources) andalso length(Resources) =< 65536),
    true_or_fail(is_list(Links) andalso length(Links) =< 65536),
    lists:foreach(fun(R) ->
        _ = tmux_workspace_wire:fields(R, [<<"kind">>, <<"id">>, <<"tag">>,
            <<"name">>, <<"parent">>, <<"index">>, <<"layout">>], []),
        true_or_fail(map_size(R) =:= 7),
        K = maps:get(<<"kind">>, R),
        id(K, maps:get(<<"id">>, R)),
        case K of
            <<"pane">> ->
                id(<<"window">>, maps:get(<<"parent">>, R)),
                true_or_fail(is_integer(maps:get(<<"index">>, R), 0, 2147483647)),
                true_or_fail(maps:get(<<"name">>, R) =:= null andalso
                             maps:get(<<"layout">>, R) =:= null);
            _ ->
                true_or_fail(is_binary(maps:get(<<"name">>, R))),
                true_or_fail(maps:get(<<"parent">>, R) =:= null andalso
                             maps:get(<<"index">>, R) =:= null),
                true_or_fail(case K of
                    <<"window">> -> is_binary(maps:get(<<"layout">>, R));
                    _ -> maps:get(<<"layout">>, R) =:= null
                end)
        end,
        case maps:get(<<"tag">>, R) of
            null -> ok;
            Tag -> _ = parse_tag(Tag, K), ok
        end
    end, Resources),
    Refs = [ref(R) || R <- Resources],
    true_or_fail(length(Refs) =:= length(lists:usort(Refs))),
    lists:foreach(fun(L) ->
        _ = tmux_workspace_wire:fields(L,
            [<<"session">>, <<"window">>, <<"index">>], []),
        true_or_fail(map_size(L) =:= 3),
        id(<<"session">>, maps:get(<<"session">>, L)),
        id(<<"window">>, maps:get(<<"window">>, L)),
        true_or_fail(is_integer(maps:get(<<"index">>, L), 0, 2147483647)),
        true_or_fail(lists:member(ref(<<"session">>, maps:get(<<"session">>, L)), Refs)),
        true_or_fail(lists:member(ref(<<"window">>, maps:get(<<"window">>, L)), Refs))
    end, Links),
    true_or_fail(lists:all(fun(R) ->
        maps:get(<<"kind">>, R) =/= <<"pane">> orelse
            lists:member(ref(<<"window">>, maps:get(<<"parent">>, R)), Refs)
    end, Resources)),
    M.

parse_tag(Tag, Kind) ->
    Fields = [<<"version">>, <<"workspace">>, <<"key">>, <<"kind">>,
        <<"instance">>, <<"parent">>, <<"launch">>, <<"layout">>, <<"children">>],
    _ = tmux_workspace_wire:fields(Tag, Fields, [<<"tag">>]),
    true_or_fail(map_size(Tag) =:= length(Fields)),
    true_or_fail(maps:get(<<"version">>, Tag) =:= 1),
    true_or_fail(maps:get(<<"kind">>, Tag) =:= Kind),
    lists:foreach(fun(F) ->
        B = tmux_workspace_wire:text(maps:get(F, Tag), [F]),
        true_or_fail(byte_size(B) =< 128)
    end, [<<"workspace">>, <<"key">>, <<"instance">>]),
    Parent = maps:get(<<"parent">>, Tag),
    true_or_fail(Parent =:= null orelse
        (is_binary(Parent) andalso byte_size(Parent) > 0 andalso byte_size(Parent) =< 128)),
    Launch = maps:get(<<"launch">>, Tag),
    true_or_fail(Launch =:= null orelse
        (is_binary(Launch) andalso byte_size(Launch) =:= 64)),
    case maps:get(<<"layout">>, Tag) of
        null -> ok;
        #{<<"name">> := Name, <<"hash">> := Hash} = Layout ->
            true_or_fail(map_size(Layout) =:= 2 andalso is_binary(Name)
                andalso is_binary(Hash) andalso byte_size(Hash) =:= 64);
        _ -> tmux_workspace_wire:fail(invalid_plan, [])
    end,
    Children = maps:get(<<"children">>, Tag),
    true_or_fail(is_list(Children) andalso length(Children) =< 64),
    lists:foreach(fun(C) ->
        _ = tmux_workspace_wire:fields(C, [<<"key">>, <<"id">>], []),
        true_or_fail(map_size(C) =:= 2),
        #{<<"key">> := Key, <<"id">> := Id} = C,
        _ = tmux_workspace_wire:text(Key, []),
        true_or_fail(byte_size(Key) =< 128),
        case Kind of
            <<"session">> -> id(<<"window">>, Id);
            <<"window">> -> id(<<"pane">>, Id);
            _ -> tmux_workspace_wire:fail(invalid_plan, [])
        end
    end, Children),
    true_or_fail(length(Children) =:= length(lists:usort(
        [maps:get(<<"key">>, C) || C <- Children]))),
    true_or_fail(length(Children) =:= length(lists:usort(
        [maps:get(<<"id">>, C) || C <- Children]))),
    Tag.

-spec id(binary(), term()) -> ok.
id(Kind, <<Prefix, Digits/binary>> = Id) when byte_size(Id) =< 22 ->
    Expected = case Kind of <<"session">> -> $$; <<"window">> -> $@;
        <<"pane">> -> $%; _ -> 0 end,
    Good = Prefix =:= Expected andalso byte_size(Digits) > 0 andalso
        lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)),
    true_or_fail(Good),
    N = binary_to_integer(Digits),
    true_or_fail(is_integer(N, 0, 18446744073709551615) andalso
                 integer_to_binary(N) =:= Digits);
id(_, _) -> tmux_workspace_wire:fail(invalid_plan, []).

-spec ref(map()) -> binary().
ref(R) -> ref(maps:get(<<"kind">>, R), maps:get(<<"id">>, R)).
-spec ref(binary(), binary()) -> binary().
ref(K, Id) -> <<K/binary, $:, Id/binary>>.

-spec resource(binary(), map()) -> map().
resource(Ref, State) ->
    case [R || R <- maps:get(<<"resources">>, State), ref(R) =:= Ref] of
        [R] -> R;
        _ -> conflict(target_gone, Ref)
    end.

-spec children(map(), map()) -> [map()].
children(#{<<"kind">> := <<"session">>, <<"id">> := Id}, State) ->
    [resource(ref(<<"window">>, maps:get(<<"window">>, L)), State)
        || L <- lists:sort(fun(A, B) -> maps:get(<<"index">>, A) < maps:get(<<"index">>, B) end,
            [L || L <- maps:get(<<"links">>, State), maps:get(<<"session">>, L) =:= Id])];
children(#{<<"kind">> := <<"window">>, <<"id">> := Id}, State) ->
    lists:sort(fun(A, B) -> maps:get(<<"index">>, A) < maps:get(<<"index">>, B) end,
        [R || R <- maps:get(<<"resources">>, State),
            maps:get(<<"parent">>, R) =:= Id]);
children(_, _) -> [].

-spec desired_nodes(map()) -> [map()].
desired_nodes(#{sessions := Sessions}) ->
    lists:append([begin
        #{key := SK, windows := Windows} = S,
        [S#{kind => <<"session">>, parent => null} |
            lists:append([begin
                #{key := WK, panes := Panes} = W,
                [W#{kind => <<"window">>, parent => SK} |
                    [P#{kind => <<"pane">>, parent => WK, order => I - 1,
                        launch_hash => tmux_workspace_wire:digest(
                            maps:with([launch, cwd], P))}
                        || {I, P} <- lists:enumerate(Panes)]]
            end || W <- Windows])]
    end || S <- Sessions]).

-spec tag(map(), map(), map(), map()) -> map().
tag(Document, Node, Bindings, State) ->
    #{key := Key, kind := Kind, parent := Parent} = Node,
    R = resource(maps:get(Key, Bindings), State),
    Layout = case maps:find(layout, Node) of
        {ok, Name} -> #{<<"name">> => Name, <<"hash">> =>
            tmux_workspace_wire:digest(maps:get(<<"layout">>, R))};
        error -> null
    end,
    #{<<"version">> => 1, <<"workspace">> => maps:get(id, Document),
      <<"key">> => Key, <<"kind">> => Kind,
      <<"instance">> => maps:get(<<"instance">>, State),
      <<"parent">> => Parent, <<"launch">> => maps:get(launch_hash, Node, null),
      <<"layout">> => Layout,
      <<"children">> => [#{<<"key">> => CK,
          <<"id">> => maps:get(<<"id">>, resource(maps:get(CK, Bindings), State))}
          || #{key := CK, parent := PK} <- desired_nodes(Document), PK =:= Key]}.

-spec checkpoint(map()) -> ok.
checkpoint(Options) ->
    case maps:get(cancel, Options, none) of
        Ref when is_reference(Ref) -> receive
            {tmux_workspace_cancel, Ref} -> tmux_workspace_wire:fail(cancelled, [])
        after 0 -> ok end;
        _ -> ok
    end.

-spec conflict(atom(), term()) -> no_return().
conflict(Reason, Target) ->
    throw({workspace_error, #{code => plan_conflict, reason => Reason,
                             target => Target, path => []}}).

result({ok, Value}) -> Value;
result({error, Detail}) -> throw({workspace_error, Detail}).
true_or_fail(true) -> ok;
true_or_fail(false) -> tmux_workspace_wire:fail(invalid_plan, []).
