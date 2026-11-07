-module(tmux_select).
-moduledoc """
Filter ordered captured rows without tmux I/O.

Use panes/windows/window_links/sessions with a snapshot to retain graph
coverage. from_list preserves supplied order, duplicates and row origins;
it establishes only fields present in every row and loads no relationships.
Filtering and take retain the original coverage even if no rows remain.

where accepts map criteria or a portable filter. filter accepts a unary
Boolean function, whose exceptions propagate. Cardinality criteria validate
the whole expression and its coverage before stopping at sufficient evidence.
Selections are opaque values; use to_list for ordinary list functions.
""".
-export([panes/1, windows/1, window_links/1, sessions/1, from_list/2,
         where/2, try_where/2, filter/2, matching/2, to_list/1, fold/3,
         take/2, summary/1, size/1, first/1, first/2, one/1, one/2,
         one_or_none/1, one_or_none/2, one_or_error/1, one_or_error/2,
         exists/1, exists/2, count/1, count/2]).
-export_type([t/0, t/1]).
-compile({no_auto_import, [size/1]}).
-record(selection, {entity :: tmux_schema:entity(), rows :: [tmux_model:row()],
                    size :: non_neg_integer(),
                    context :: {snapshot, tmux_snapshot:t()} | {local, map()}}).
-opaque t(Row) :: #selection{rows :: [Row]}.
-type t() :: t(tmux_model:row()).
-type criteria() :: map() | tmux_filter:t().
-type cardinality_error() :: {error, no_match | {multiple_matches, #{at_least := 2}}}.

-spec panes(tmux_snapshot:t()) -> t(tmux_model:pane()).
panes(Snapshot) -> from_snapshot(pane, Snapshot).
-spec windows(tmux_snapshot:t()) -> t(tmux_model:window()).
windows(Snapshot) -> from_snapshot(window, Snapshot).
-spec window_links(tmux_snapshot:t()) -> t(tmux_model:window_link()).
window_links(Snapshot) -> from_snapshot(window_link, Snapshot).
-spec sessions(tmux_snapshot:t()) -> t(tmux_model:session()).
sessions(Snapshot) -> from_snapshot(session, Snapshot).

-doc """
Validate an ordinary list without rebinding, reordering or deduplicating it.

```erlang
1> {ok, P} = tmux_model:pane(#{id => <<"%1">>, width => 120}), ok.
ok
2> S = tmux_select:from_list(pane, [P, P]), ok.
ok
3> tmux_select:size(tmux_select:where(#{width => #{gte => 120}}, S)).
2
4> tmux_select:one(S).
{error,{multiple_matches,#{at_least => 2}}}
```
""".
-spec from_list(tmux_schema:entity(), [Row]) -> t(Row) when Row :: tmux_model:row().
from_list(Entity, Rows) ->
    case tmux_schema:fields(Entity) of
        {ok, Fields} ->
            validate_rows(Entity, Rows, 0),
            Coverage = maps:map(fun(Field, _) -> field_coverage(Field, Rows) end, Fields),
            #selection{entity = Entity, rows = Rows, size = length(Rows),
                       context = {local, Coverage}};
        {error, Detail} -> error({bad_selection, Detail})
    end.

-spec where(criteria(), t(Row)) -> t(Row) when Row :: tmux_model:row().
where(Criteria, Selection) ->
    case try_where(Criteria, Selection) of
        {ok, Result} -> Result;
        {error, Detail} -> raise_filter(Detail)
    end.

-spec try_where(criteria(), t(Row)) -> {ok, t(Row)} | {error, map()} when Row :: tmux_model:row().
try_where(Criteria, #selection{rows = Rows} = Selection) ->
    maybe
        {ok, Prepared} ?= prepare(Criteria, Selection),
        {ok, Matches} ?= select_rows(Prepared, Rows, []),
        {ok, with_rows(Matches, Selection)}
    end.

-spec filter(fun((Row) -> boolean()), t(Row)) -> t(Row) when Row :: tmux_model:row().
filter(Predicate, #selection{rows = Rows} = Selection) when is_function(Predicate, 1) ->
    with_rows(lists:filter(Predicate, Rows), Selection).

-doc """
Prepare a trusted behaviour once, then apply its Boolean predicate.

Returns {error, Detail} on matcher preparation failure. Exceptions in either
callback propagate. A matcher requires a captured snapshot; a from_list
selection returns matcher_requires_snapshot. The application chooses Module.
""".
-spec matching({module(), term()}, t(Row)) -> {ok, t(Row)} | {error, term()} when Row :: tmux_model:row().
matching({Module, State}, #selection{context = {snapshot, Snapshot}} = Selection)
  when is_atom(Module) ->
    case Module:prepare(State, Snapshot) of
        {ok, Predicate} when is_function(Predicate, 1) -> {ok, filter(Predicate, Selection)};
        {error, _} = Error -> Error;
        _ -> error(invalid_matcher_result)
    end;
matching({Module, _}, #selection{}) when is_atom(Module) ->
    {error, #{code => matcher_requires_snapshot}}.

-spec to_list(t(Row)) -> [Row] when Row :: tmux_model:row().
to_list(#selection{rows = Rows}) -> Rows.
-spec fold(fun((Row, Acc) -> Acc), Acc, t(Row)) -> Acc when Row :: tmux_model:row().
fold(Function, Accumulator, #selection{rows = Rows}) -> lists:foldl(Function, Accumulator, Rows).
-spec take(non_neg_integer(), t(Row)) -> t(Row) when Row :: tmux_model:row().
take(Count, #selection{rows = Rows} = Selection) when is_integer(Count), Count >= 0 ->
    with_rows(lists:sublist(Rows, Count), Selection).
-spec size(t()) -> non_neg_integer().
size(#selection{size = Size}) -> Size.

-spec summary(t()) -> map().
summary(#selection{entity = Entity, size = Size, context = Context}) ->
    Base = #{entity => Entity, size => Size},
    case Context of
        {snapshot, Snapshot} ->
            Meta = tmux_snapshot:metadata(Snapshot),
            maps:merge(Base#{snapshot_id => maps:get(id, Meta),
                             coverage => maps:get(Entity, tmux_snapshot:coverage(Snapshot))},
                       maps:with([capture_started, capture_finished, time_unit], Meta));
        {local, Coverage} ->
            {ok, Relations} = tmux_schema:relations(Entity),
            Base#{snapshot_id => none, coverage => #{collection => complete, fields => Coverage,
                       relations => maps:map(fun(_, _) -> not_loaded end, Relations)}}
    end.

-spec first(t(Row)) -> {ok, Row} | none when Row :: tmux_model:row().
first(#selection{rows = []}) -> none;
first(#selection{rows = [Row | _]}) -> {ok, Row}.
-spec first(criteria(), t(Row)) -> {ok, Row} | none when Row :: tmux_model:row().
first(Criteria, Selection) -> first(matching_prefix(Criteria, Selection, 1)).

-spec one(t(Row)) -> {ok, Row} | cardinality_error() when Row :: tmux_model:row().
one(#selection{rows = []}) -> {error, no_match};
one(#selection{rows = [Row]}) -> {ok, Row};
one(#selection{rows = [_, _ | _]}) -> {error, {multiple_matches, #{at_least => 2}}}.
-spec one(criteria(), t(Row)) -> {ok, Row} | cardinality_error() when Row :: tmux_model:row().
one(Criteria, Selection) -> one(matching_prefix(Criteria, Selection, 2)).

-spec one_or_none(t(Row)) -> {ok, Row | none} | cardinality_error() when Row :: tmux_model:row().
one_or_none(Selection) ->
    case one(Selection) of {error, no_match} -> {ok, none}; Result -> Result end.
-spec one_or_none(criteria(), t(Row)) -> {ok, Row | none} | cardinality_error() when Row :: tmux_model:row().
one_or_none(Criteria, Selection) -> one_or_none(matching_prefix(Criteria, Selection, 2)).

-spec one_or_error(t(Row)) -> Row when Row :: tmux_model:row().
one_or_error(Selection) ->
    case one(Selection) of
        {ok, Row} -> Row;
        {error, Reason} -> error(Reason)
    end.
-spec one_or_error(criteria(), t(Row)) -> Row when Row :: tmux_model:row().
one_or_error(Criteria, Selection) -> one_or_error(matching_prefix(Criteria, Selection, 2)).

-spec exists(t()) -> boolean().
exists(#selection{size = Size}) -> Size > 0.
-spec exists(criteria(), t()) -> boolean().
exists(Criteria, Selection) -> exists(matching_prefix(Criteria, Selection, 1)).
-spec count(t()) -> non_neg_integer().
count(Selection) -> size(Selection).
-spec count(criteria(), t()) -> non_neg_integer().
count(Criteria, #selection{rows = Rows} = Selection) ->
    Prepared = prepare_or_error(Criteria, Selection),
    lists:foldl(fun(Row, Acc) -> case match(Prepared, Row) of
        true -> Acc + 1; false -> Acc end end, 0, Rows).

from_snapshot(Entity, Snapshot) ->
    Rows = tmux_snapshot:rows(Entity, Snapshot),
    #selection{entity = Entity, rows = Rows, size = length(Rows), context = {snapshot, Snapshot}}.
with_rows(Rows, Selection) -> Selection#selection{rows = Rows, size = length(Rows)}.

validate_rows(_, [], _) -> ok;
validate_rows(Entity, [Row | Rest], Index) ->
    case tmux_model:validate(Row) of
        {ok, Row} ->
            case tmux_model:entity(Row) of
                Entity -> validate_rows(Entity, Rest, Index + 1);
                _ -> error({bad_selection, #{code => wrong_row_entity, path => [Index]}})
            end;
        {error, Detail} -> error({bad_selection, Detail#{path => [Index | maps:get(path, Detail, [])]}})
    end;
validate_rows(_, _, Index) -> error({bad_selection, #{code => expected_array, path => [Index]}}).

field_coverage(_, []) -> not_loaded;
field_coverage(Field, Rows) ->
    lists:foldl(fun(Row, State) ->
        case {tmux_model:get(Field, Row), State} of
            {unavailable, _} -> unavailable;
            {_, unavailable} -> unavailable;
            {not_loaded, _} -> not_loaded;
            {_, _} -> State
        end
    end, loaded, Rows).

prepare(Criteria, #selection{entity = Entity, rows = Rows, context = Context}) ->
    maybe
        {ok, Filter} ?= tmux_filter:new(Entity, Criteria),
        case Context of
            {snapshot, Snapshot} -> tmux_filter:prepare(Filter, Snapshot);
            {local, Coverage} -> tmux_filter:prepare_rows(Filter, Rows, Coverage)
        end
    end.
prepare_or_error(Criteria, Selection) ->
    case prepare(Criteria, Selection) of
        {ok, Prepared} -> Prepared;
        {error, Detail} -> raise_filter(Detail)
    end.
-spec raise_filter(map()) -> no_return().
raise_filter(#{code := incomplete_snapshot} = Detail) -> error({incomplete_snapshot, Detail});
raise_filter(#{code := Code} = Detail) when Code =:= unsupported_regex_subject;
        Code =:= regex_subject_limit; Code =:= regex_resource_limit ->
    error({filter_evaluation_failed, Detail});
raise_filter(Detail) -> error({bad_filter, Detail}).

select_rows(_, [], Acc) -> {ok, lists:reverse(Acc)};
select_rows(Prepared, [Row | Rest], Acc) ->
    case tmux_filter:matches(Prepared, Row) of
        {ok, true} -> select_rows(Prepared, Rest, [Row | Acc]);
        {ok, false} -> select_rows(Prepared, Rest, Acc);
        {error, _} = Error -> Error
    end.
match(Prepared, Row) ->
    case tmux_filter:matches(Prepared, Row) of
        {ok, Boolean} -> Boolean;
        {error, Detail} -> error({filter_evaluation_failed, Detail})
    end.
matching_prefix(Criteria, #selection{rows = Rows} = Selection, Limit) ->
    Prepared = prepare_or_error(Criteria, Selection),
    with_rows(prefix(Prepared, Rows, Limit, []), Selection).
prefix(_, _, 0, Acc) -> lists:reverse(Acc);
prefix(_, [], _, Acc) -> lists:reverse(Acc);
prefix(Prepared, [Row | Rest], Limit, Acc) ->
    case match(Prepared, Row) of
        true -> prefix(Prepared, Rest, Limit - 1, [Row | Acc]);
        false -> prefix(Prepared, Rest, Limit, Acc)
    end.
