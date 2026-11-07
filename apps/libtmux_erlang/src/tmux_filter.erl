-module(tmux_filter).
-moduledoc """
Construct portable conditions and prepare them against captured values.

Local criteria use atom keys, binary text and schema-typed values. Fields and
operators conjoin. Boolean branches use 'and', 'or' and 'not'; relationships
use some/every/none/count or is/is_not. Validation examines the entire input
before evaluation. No function here performs tmux I/O.

```erlang
1> {ok, P} = tmux_model:pane(#{id => <<"%1">>, current_command => <<"vim">>}), ok.
ok
2> S = tmux_select:from_list(pane, [P]), ok.
ok
3> R = #{pattern => <<"^(vim|nvim)$">>, dialect => portable_v1}, ok.
ok
4> tmux_select:size(tmux_select:where(#{current_command => #{regex => R}}, S)).
1
```

Wire version 1 uses generated camelCase field names, snake_case operators,
JSON null for known absence and {"base64": "..."} for byte operands. Byte
values never become text implicitly. Regex uses the restricted ASCII
portable_v1 dialect, absolute anchors and no flags. Preparation compiles each
pattern once. Non-ASCII subjects and exhausted match limits return errors.

Both input criteria and their normalized wire document must fit the grammar,
depth and byte limits. Resource errors can refer to the canonical wire path.
""".
-export([new/2, new_or_error/2, from_wire/2, to_wire/1, decode_json/1,
         entity/1, expression/1, requirements/1, prepare/2, predicate/1, matches/2,
         prepare_rows/3]).
-export_type([t/0, prepared/0, expr/0]).
-opaque t() :: {tmux_filter, 1, tmux_schema:entity(), expr()}.
-type expr() :: {all | any, [expr()]} | {negate, expr()} |
    {field, binary(), atom(), term()} |
    {relation, binary(), atom(), expr()} |
    {count, binary(), [{atom(), term()}]}.
-type prepared() :: tmux_filter_eval:t().
-define(MAX_NODES, 1024).
-define(MAX_DEPTH, 32).
-define(MAX_MEMBERS, 256).

-doc """
Validate criteria or reuse an already normalized filter for the same entity.

```erlang
1> {ok, F} = tmux_filter:new(pane, #{width => #{gte => 120.0}}), ok.
ok
2> tmux_filter:new(pane, F) =:= {ok, F}.
true
3> tmux_filter:new(pane, #{active => #{contains => <<"yes">>}}).
{error,#{code => unsupported_operator,path => [active,contains],allowed => [equals,'not',in,not_in]}}
```
""".
-spec new(tmux_schema:entity(), map() | t()) -> {ok, t()} | {error, map()}.
new(Entity, {tmux_filter, 1, Entity, _} = Filter) -> {ok, Filter};
new(_Entity, {tmux_filter, _, _, _}) ->
    {error, #{code => wrong_filter_entity, path => []}};
new(Entity, Criteria) -> construct(Entity, Criteria, local, []).

-spec new_or_error(tmux_schema:entity(), map() | t()) -> t().
new_or_error(Entity, Criteria) ->
    case new(Entity, Criteria) of
        {ok, Filter} -> Filter;
        {error, Detail} -> error({bad_filter, Detail})
    end.

-spec from_wire(tmux_schema:entity(), term()) -> {ok, t()} | {error, map()}.
from_wire(Entity, Document) ->
    validated(fun() ->
        schema(Entity),
        object(Document, []),
        only_keys(Document, [<<"version">>, <<"entity">>, <<"where">>], []),
        case maps:get(<<"version">>, Document, missing) of
            1 -> ok;
            _ -> fail(unsupported_version, [<<"version">>])
        end,
        EntityName = tmux_schema_data:wire_entity(Entity),
        case maps:get(<<"entity">>, Document, missing) of
            EntityName -> ok;
            _ -> fail(wrong_filter_entity, [<<"entity">>])
        end,
        case maps:find(<<"where">>, Document) of
            {ok, Criteria} -> build(Entity, Criteria, wire, [<<"where">>]);
            error -> fail(required_field, [<<"where">>])
        end
    end).

-spec to_wire(t()) -> map().
to_wire({tmux_filter, 1, Entity, Tree}) ->
    #{<<"version">> => 1, <<"entity">> => tmux_schema_data:wire_entity(Entity),
      <<"where">> => wire_node(Entity, Tree)}.

-spec decode_json(binary()) -> {ok, json:decode_value()} | {error, map()}.
decode_json(Binary) -> tmux_json:decode(Binary).

-spec entity(t()) -> tmux_schema:entity().
entity({tmux_filter, 1, Entity, _}) -> Entity.

%% Internal planner boundary. The expression contains data and stable IDs only.
-doc false.
-spec expression(t()) -> expr().
expression({tmux_filter, 1, _, Tree}) -> Tree.

-spec requirements(t()) -> [tmux_snapshot:requirement()].
requirements({tmux_filter, 1, Entity, Tree}) ->
    lists:usort([{collection, Entity} | needed(Entity, Tree)]).

-doc """
Bind a filter to one snapshot and check all required coverage first.

The prepared value can match only unmodified rows captured in that snapshot.
It remains usable after the endpoint closes. It cannot refresh observations.

```erlang
1> {ok, F} = tmux_filter:new(pane, #{width => #{gte => 80}}), ok.
ok
2> tmux_filter:requirements(F).
[{collection,pane},{field,pane,width}]
```
""".
-spec prepare(t(), tmux_snapshot:t()) -> {ok, prepared()} | {error, map()}.
prepare({tmux_filter, 1, Entity, Tree} = Filter, Snapshot) ->
    maybe
        ok ?= tmux_snapshot:require(requirements(Filter), Snapshot),
        tmux_filter_eval:prepare(Entity, Tree, {snapshot, Snapshot})
    end.

%% Selection construction validates rows and retains its original coverage.
%% Preparing a subset must not turn an unloaded field into a known value.
-doc false.
-spec prepare_rows(t(), [tmux_model:row()], map()) -> {ok, prepared()} | {error, map()}.
prepare_rows({tmux_filter, 1, Entity, Tree} = Filter, Rows, Coverage) ->
    Missing = [#{requirement => R, state => coverage_state(R, Entity, Coverage)}
               || R <- requirements(Filter),
                  not lists:member(coverage_state(R, Entity, Coverage), [complete, loaded])],
    case Missing of
        [] -> tmux_filter_eval:prepare(Entity, Tree, {rows, maps:from_keys(Rows, true)});
        _ -> {error, #{code => incomplete_snapshot, requirements => Missing}}
    end.

-doc """
Return a Boolean function bound to the prepared observation context.

Rows outside that context raise {prepared_context_mismatch, Detail}. Regex
evaluation errors raise {filter_evaluation_failed, Detail}. Use matches/2 for
tagged errors. This does not run callbacks.
""".
-spec predicate(prepared()) -> fun((tmux_model:row()) -> boolean()).
predicate(Prepared) ->
    fun(Row) ->
        case matches(Prepared, Row) of
            {ok, Boolean} -> Boolean;
            {error, #{code := prepared_context_mismatch} = Detail} ->
                error({prepared_context_mismatch, Detail});
            {error, Detail} -> error({filter_evaluation_failed, Detail})
        end
    end.

-spec matches(prepared(), tmux_model:row()) -> {ok, boolean()} | {error, map()}.
matches(Prepared, Row) -> tmux_filter_eval:matches(Prepared, Row).

construct(Entity, Criteria, Mode, Path) ->
    validated(fun() -> schema(Entity), build(Entity, Criteria, Mode, Path) end).

build(Entity, Criteria, Mode, Path) ->
    {Tree, _} = expression(Entity, Criteria, Mode, Path, 1, 0),
    Filter = {tmux_filter, 1, Entity, Tree},
    Wire = to_wire(Filter),
    %% Conjunctive leaves can expand a compact input. Check the representation
    %% we actually export so an accepted filter can cross the same boundary.
    {Tree, _} = expression(Entity, maps:get(<<"where">>, Wire), wire, [<<"where">>], 1, 0),
    Encoded = iolist_to_binary(json:encode(Wire)),
    case tmux_json:decode(Encoded) of
        {ok, _} -> Filter;
        {error, Detail} -> fail(Detail)
    end.

validated(Function) ->
    try {ok, Function()}
    catch throw:{invalid_filter, Detail} -> {error, Detail}
    end.

schema(Entity) ->
    case tmux_schema:fields(Entity) of
        {ok, _} -> ok;
        {error, Detail} -> throw({invalid_filter, Detail})
    end.

expression(Entity, Input, Mode, Path, Depth, Count) ->
    Next = budget(Depth, Count, Path),
    object(Input, Path),
    {Nodes, Final} = entries(lists:sort(maps:to_list(Input)), Entity, Mode,
                           Path, Depth, Next, []),
    {conjunction(Nodes), Final}.

entries([], _, _, _, _, Count, Acc) -> {lists:reverse(Acc), Count};
entries([{Key, Value} | Rest], Entity, Mode, Path, Depth, Count, Acc) ->
    Here = Path ++ [Key],
    {Node, Next} = case resolve(Key, Mode, boolean_names()) of
        {ok, 'not'} ->
            {Child, N} = expression(Entity, Value, Mode, Here, Depth + 1, Count),
            {{negate, Child}, N};
        {ok, Boolean} ->
            {Children, N} = branches(Value, Entity, Mode, Here, Depth + 1, Count, 0, []),
            {{case Boolean of 'and' -> all; 'or' -> any end, Children}, N};
        error -> member(Entity, Key, Value, Mode, Here, Depth, Count)
    end,
    entries(Rest, Entity, Mode, Path, Depth, Next, [Node | Acc]).

branches([], _, _, _, _, Count, _, Acc) -> {lists:reverse(Acc), Count};
branches([Value | Rest], Entity, Mode, Path, Depth, Count, Index, Acc) ->
    {Node, Next} = expression(Entity, Value, Mode, Path ++ [Index], Depth, Count),
    branches(Rest, Entity, Mode, Path, Depth, Next, Index + 1, [Node | Acc]);
branches(_, _, _, Path, _, _, _, _) -> fail(expected_array, Path).

member(Entity, Key, Value, Mode, Path, Depth, Count) ->
    Fields = tmux_schema_data:fields(Entity),
    Relations = tmux_schema_data:relations(Entity),
    case {resolve_meta(Key, Mode, Fields), resolve_meta(Key, Mode, Relations)} of
        {{ok, _, Meta}, _} ->
            {Ops, Next} = operators(Value, Meta, Mode, Path, Depth, Count),
            {conjunction([{field, maps:get(stable, Meta), Op, V} || {Op, V} <- Ops]), Next};
        {error, {ok, _, Meta}} -> relation(Value, Meta, Mode, Path, Depth, Count);
        _ -> fail(#{code => unknown_field, path => Path,
                    allowed => names(Mode, maps:merge(Fields, Relations))})
    end.

operators(Input, Meta, Mode, Path, Depth, Count) ->
    IsBytes = Mode =:= wire andalso maps:get(type, Meta) =:= bytes andalso
              is_map(Input) andalso is_map_key(<<"base64">>, Input),
    case is_map(Input) andalso not IsBytes of
        true when map_size(Input) =:= 0 -> fail(empty_operators, Path);
        true -> scalar_ops(lists:sort(maps:to_list(Input)), Meta, Mode, Path, Depth, Count, []);
        false -> {[{equals, scalar(Meta, Input, Mode, Path)}], budget(Depth, Count, Path)}
    end.

scalar_ops([], _, _, _, _, Count, Acc) -> {lists:reverse(Acc), Count};
scalar_ops([{Key, Value} | Rest], Meta, Mode, Path, Depth, Count, Acc) ->
    Here = Path ++ [Key],
    Next = budget(Depth, Count, Here),
    Allowed = tmux_schema:operators(Meta),
    Op = operator(Key, Mode, Allowed, Here),
    Normalized = case Op of
        present when is_boolean(Value) -> Value;
        present -> fail(expected_boolean, Here);
        in -> members(Value, Meta, Mode, Here, 0, []);
        not_in -> members(Value, Meta, Mode, Here, 0, []);
        regex -> regex(Value, Mode, Here);
        equals -> scalar(Meta, Value, Mode, Here);
        'not' -> scalar(Meta, Value, Mode, Here);
        _ -> scalar(Meta#{nullable => false}, Value, Mode, Here)
    end,
    scalar_ops(Rest, Meta, Mode, Path, Depth, Next, [{Op, Normalized} | Acc]).

regex(Input, Mode, Path) ->
    object(Input, Path),
    Key = fun(Name) -> case Mode of local -> Name; wire -> atom_to_binary(Name) end end,
    PatternKey = Key(pattern),
    DialectKey = Key(dialect),
    FlagsKey = Key(flags),
    only_keys(Input, [PatternKey, DialectKey, FlagsKey], Path),
    Dialect = case Mode of local -> portable_v1; wire -> <<"portable_v1">> end,
    case maps:get(DialectKey, Input, missing) of
        Dialect -> ok;
        _ -> fail(unsupported_dialect, Path ++ [DialectKey])
    end,
    case maps:get(FlagsKey, Input, []) of
        [] -> ok;
        _ -> fail(unsupported_regex_flags, Path ++ [FlagsKey])
    end,
    Pattern = case maps:find(PatternKey, Input) of
        {ok, Value} -> Value;
        error -> fail(required_field, Path ++ [PatternKey])
    end,
    case tmux_regex:validate(Pattern) of
        {ok, _} -> #{pattern => Pattern, dialect => portable_v1, flags => []};
        {error, Detail} -> fail(Detail#{path => Path ++ [PatternKey]})
    end.

members([], _, _, _, _, Acc) -> lists:usort(Acc);
members([_ | _], _, _, Path, ?MAX_MEMBERS, _) -> fail(membership_limit, Path);
members([Value | Rest], Meta, Mode, Path, Index, Acc) ->
    Normalized = scalar(Meta, Value, Mode, Path ++ [Index]),
    members(Rest, Meta, Mode, Path, Index + 1, [Normalized | Acc]);
members(_, _, _, Path, _, _) -> fail(expected_array, Path).

scalar(Meta, Input, Mode, Path) ->
    Value = case {Mode, maps:get(type, Meta), Input} of
        {wire, _, null} -> none;
        {wire, bytes, #{<<"base64">> := Encoded} = Object} when map_size(Object) =:= 1,
                                                                     is_binary(Encoded) ->
            try
                Bytes = base64:decode(Encoded),
                case base64:encode(Bytes) of
                    Encoded -> Bytes;
                    _ -> fail(invalid_bytes, Path)
                end
            catch error:_ -> fail(invalid_bytes, Path)
            end;
        {wire, bytes, _} -> fail(invalid_bytes, Path);
        _ -> Input
    end,
    case tmux_schema:value(Meta, Value) of
        {ok, Normalized} -> Normalized;
        {error, Detail} -> fail(Detail#{path => Path})
    end.

relation(Input, #{kind := Kind, target := Target, stable := Stable}, Mode, Path, Depth, Count) ->
    object(Input, Path),
    case map_size(Input) of 0 -> fail(empty_operators, Path); _ -> ok end,
    Allowed = case Kind of many -> [some, every, none, count]; one -> [is, is_not] end,
    {Nodes, Final} = lists:mapfoldl(fun({Key, Value}, N) ->
        Here = Path ++ [Key],
        Next = budget(Depth, N, Here),
        Op = operator(Key, Mode, Allowed, Here),
        case Op of
            count ->
                {Ops, Last} = operators(Value, #{type => uint, nullable => false},
                                        Mode, Here, Depth + 1, Next),
                {{count, Stable, Ops}, Last};
            _ ->
                {Child, Last} = expression(Target, Value, Mode, Here, Depth + 1, Next),
                {{relation, Stable, Op, Child}, Last}
        end
    end, Count, lists:sort(maps:to_list(Input))),
    {conjunction(Nodes), Final}.

operator(Key, Mode, Allowed, Path) ->
    case resolve(Key, Mode, [{Op, atom_to_binary(Op)} || Op <- Allowed]) of
        {ok, Op} -> Op;
        error -> fail(#{code => unsupported_operator, path => Path,
                        allowed => case Mode of local -> Allowed;
                            wire -> [atom_to_binary(Op) || Op <- Allowed] end})
    end.

boolean_names() -> [{'and', <<"and">>}, {'or', <<"or">>}, {'not', <<"not">>}].
resolve(Key, local, Choices) ->
    case lists:keyfind(Key, 1, Choices) of {Key, _} -> {ok, Key}; false -> error end;
resolve(Key, wire, Choices) ->
    case lists:keyfind(Key, 2, Choices) of {Name, Key} -> {ok, Name}; false -> error end.
resolve_meta(Key, Mode, Items) ->
    case resolve(Key, Mode, [{Name, maps:get(wire, M)} || {Name, M} <- maps:to_list(Items)]) of
        {ok, Name} -> {ok, Name, maps:get(Name, Items)};
        error -> error
    end.
names(local, Items) -> lists:sort(maps:keys(Items));
names(wire, Items) -> lists:sort([maps:get(wire, M) || M <- maps:values(Items)]).

object(Value, _) when is_map(Value) -> ok;
object(_, Path) -> fail(expected_object, Path).
only_keys(Map, Allowed, Path) ->
    case lists:sort(maps:keys(maps:without(Allowed, Map))) of
        [] -> ok;
        [Key | _] -> fail(#{code => unknown_field, path => Path ++ [Key], allowed => Allowed})
    end.
budget(Depth, _, Path) when Depth > ?MAX_DEPTH -> fail(depth_limit, Path);
budget(_, Count, Path) when Count >= ?MAX_NODES -> fail(expression_limit, Path);
budget(_, Count, _) -> Count + 1.
conjunction([Node]) -> Node;
conjunction(Nodes) -> {all, Nodes}.
-spec fail(atom(), [term()]) -> no_return().
fail(Code, Path) -> fail(#{code => Code, path => Path}).
-spec fail(map()) -> no_return().
fail(Detail) -> throw({invalid_filter, Detail}).

metadata(Stable, Items) ->
    [{Name, Meta}] = [{N, M} || {N, M = #{stable := S}} <- maps:to_list(Items), S =:= Stable],
    {Name, Meta}.

needed(Entity, {Kind, Nodes}) when Kind =:= all; Kind =:= any ->
    lists:append([needed(Entity, Node) || Node <- Nodes]);
needed(Entity, {negate, Node}) -> needed(Entity, Node);
needed(Entity, {field, Stable, _, _}) ->
    {Name, _} = metadata(Stable, tmux_schema_data:fields(Entity)),
    [{field, Entity, Name}];
needed(Entity, {relation, Stable, _, Child}) ->
    {Name, #{target := Target}} = metadata(Stable, tmux_schema_data:relations(Entity)),
    [{relation, Entity, Name}, {collection, Target} | needed(Target, Child)];
needed(Entity, {count, Stable, _}) ->
    {Name, #{target := Target}} = metadata(Stable, tmux_schema_data:relations(Entity)),
    [{relation, Entity, Name}, {collection, Target}].

coverage_state({collection, Entity}, Entity, _) -> complete;
coverage_state({field, Entity, Field}, Entity, Coverage) -> maps:get(Field, Coverage);
coverage_state(_, _, _) -> not_loaded.

wire_node(Entity, {Kind, Children}) when Kind =:= all; Kind =:= any ->
    Key = case Kind of all -> <<"and">>; any -> <<"or">> end,
    #{Key => [wire_node(Entity, Child) || Child <- Children]};
wire_node(Entity, {negate, Child}) -> #{<<"not">> => wire_node(Entity, Child)};
wire_node(Entity, {field, Stable, Op, Value}) ->
    {_, Meta} = metadata(Stable, tmux_schema_data:fields(Entity)),
    #{maps:get(wire, Meta) => #{atom_to_binary(Op) => wire_value(Op, Value, Meta)}};
wire_node(Entity, {relation, Stable, Op, Child}) ->
    {_, #{target := Target, wire := Wire}} = metadata(Stable, tmux_schema_data:relations(Entity)),
    #{Wire => #{atom_to_binary(Op) => wire_node(Target, Child)}};
wire_node(Entity, {count, Stable, Ops}) ->
    {_, #{wire := Wire}} = metadata(Stable, tmux_schema_data:relations(Entity)),
    #{Wire => #{<<"count">> => maps:from_list([{atom_to_binary(Op), Value} || {Op, Value} <- Ops])}}.

wire_value(Op, Values, Meta) when Op =:= in; Op =:= not_in ->
    [wire_scalar(Value, Meta) || Value <- Values];
wire_value(present, Value, _) -> Value;
wire_value(regex, #{pattern := Pattern, dialect := portable_v1, flags := []}, _) ->
    #{<<"pattern">> => Pattern, <<"dialect">> => <<"portable_v1">>, <<"flags">> => []};
wire_value(_, Value, Meta) -> wire_scalar(Value, Meta).
wire_scalar(none, _) -> null;
wire_scalar(Value, #{type := bytes}) -> #{<<"base64">> => base64:encode(Value)};
wire_scalar(Value, _) -> Value.
