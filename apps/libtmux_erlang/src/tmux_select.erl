-module(tmux_select).
-moduledoc """
Filter ordered captured rows without tmux I/O.

Use `panes/1`, `windows/1`,
`window_links/1` or `sessions/1` with a
`m:tmux_snapshot` to retain graph coverage. `from_list/2`
preserves supplied order, duplicates and row origins; it establishes only
fields present in every row and loads no relationships. Filtering and
`take/2` retain the original coverage even if no rows remain.

`where/2` accepts map criteria or a `t:tmux_filter:t/0` portable
filter. `filter/2` accepts a unary Boolean function, whose
exceptions propagate. Cardinality criteria validate the whole expression and
its coverage before stopping at sufficient evidence. Selections are opaque
values; use `to_list/1` for functions in `m:lists`.

A snapshot-backed selection retains the complete captured graph, including
rows removed by filtering. After relationship evaluation, store the result of
`to_list/1` and release other snapshot and selection references to allow that
context to be collected. Row extraction preserves the supplied field binaries;
caller-created subbinaries can still retain their backing allocation.
""".
-export([panes/1, windows/1, window_links/1, sessions/1, from_list/2,
         where/2, try_where/2, filter/2, matching/2, to_list/1, fold/3,
         take/2, summary/1, size/1, first/1, first/2, one/1, one/2,
         one_or_none/1, one_or_none/2, one_or_error/1, one_or_error/2,
         exists/1, exists/2, count/1, count/2]).
-export_type([t/0, t/1, summary/0]).
-compile({no_auto_import, [size/1]}).
-record(selection, {entity :: tmux_schema:entity(), rows :: [tmux_model:row()],
                    size :: non_neg_integer(),
                    context :: {snapshot, tmux_snapshot:t()} | {local, map()}}).
-doc """
Ordered captured rows with observation and coverage context, not an extensible
list protocol. The parameter describes the intended row type. OTP 29
Dialyzer can widen generic return variables to their declared bounds; it does
not prove every entity relationship through `one/1` or `to_list/1`. Runtime
schema, coverage and action checks remain necessary.
""".
-opaque t(Row) :: #selection{rows :: [Row]}.
-doc """
A selection over schema-defined native domain records.
""".
-type t() :: t(tmux_model:row()).
-type criteria() :: map() | tmux_filter:t().
-type cardinality_error() :: {error, no_match | {multiple_matches, #{at_least := 2}}}.
-doc """
Compact local inspection. size counts current materialized rows; coverage
still describes the original captured context after filtering or take.
snapshot_id is none for a list-backed selection. Capture bounds and query
diagnostics are included only when that source metadata exists.
""".
-type summary() :: #{entity := tmux_schema:entity(), size := non_neg_integer(),
    snapshot_id := reference() | none, coverage := tmux_snapshot:entity_coverage(),
    capture_started => integer(), capture_finished => integer(),
    time_unit => microsecond, query => tmux_snapshot:query_metadata()}.

-doc """
Select captured physical panes while retaining snapshot graph and coverage.
Performs no I/O and preserves the snapshot's deterministic order.
""".
-spec panes(tmux_snapshot:t()) -> t(tmux_model:pane()).
panes(Snapshot) -> from_snapshot(pane, Snapshot).
-doc """
Select unique captured physical windows with their complete graph context.
Performs no I/O; session memberships remain separate window-link rows.
""".
-spec windows(tmux_snapshot:t()) -> t(tmux_model:window()).
windows(Snapshot) -> from_snapshot(window, Snapshot).
-doc """
Select all captured session memberships, retaining repeated physical windows
and session-relative indexes. Performs no I/O.
""".
-spec window_links(tmux_snapshot:t()) -> t(tmux_model:window_link()).
window_links(Snapshot) -> from_snapshot(window_link, Snapshot).
-doc """
Select captured sessions with their relationship and coverage context.
Performs no I/O.
""".
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
        {error, Detail} -> erlang:error({bad_selection, Detail}, none,
            [{error_info, #{module => tmux_error}}])
    end.

-doc """
Validate portable criteria and coverage, then preserve matching rows in order.
Performs no I/O. Malformed trusted criteria raise bad_filter; missing coverage
and runtime evaluation failures remain distinct exceptions. Use `try_where/2`
for tagged library errors.
""".
-spec where(criteria(), t(Row)) -> t(Row) when Row :: tmux_model:row().
where(Criteria, Selection) ->
    case try_where(Criteria, Selection) of
        {ok, Result} -> Result;
        {error, Detail} -> raise_filter(Detail)
    end.

-doc """
Apply the same local criteria and coverage checks as `where/2`, returning
tagged validation or evaluation errors. It does not catch arbitrary
application callback exceptions and never performs tmux I/O.
""".
-spec try_where(criteria(), t(Row)) -> {ok, t(Row)} | {error, map()} when Row :: tmux_model:row().
try_where(Criteria, #selection{rows = Rows} = Selection) ->
    maybe
        {ok, Prepared} ?= prepare(Criteria, Selection),
        {ok, Matches} ?= select_rows(Prepared, Rows, []),
        {ok, with_rows(Matches, Selection)}
    end.

-doc """
Apply an ordinary unary Boolean function locally, preserving row order and
context. Non-Booleans and callback failures propagate; they are not false
matches. This is executable application code, not portable filter data.
""".
-spec filter(fun((Row) -> boolean()), t(Row)) -> t(Row) when Row :: tmux_model:row().
filter(Predicate, #selection{rows = Rows} = Selection) when is_function(Predicate, 1) ->
    with_rows(lists:filter(Predicate, Rows), Selection).

-doc """
Prepare a trusted behaviour once, then apply its Boolean predicate.

Uses `c:tmux_matcher:prepare/2`; preparation failure returns {error, Detail}.
Exceptions in either callback propagate. A matcher requires a captured
snapshot; a `from_list/2` selection returns matcher_requires_snapshot. The
application chooses Module.
""".
-spec matching({module(), term()}, t(Row)) -> {ok, t(Row)} | {error, term()} when Row :: tmux_model:row().
matching({Module, State}, #selection{context = {snapshot, Snapshot}} = Selection)
  when is_atom(Module) ->
    case Module:prepare(State, Snapshot) of
        {ok, Predicate} when is_function(Predicate, 1) -> {ok, filter(Predicate, Selection)};
        {error, _} = Error -> Error;
        _ -> erlang:error(invalid_matcher_result, none,
            [{error_info, #{module => tmux_error}}])
    end;
matching({Module, _}, #selection{}) when is_atom(Module) ->
    {error, #{code => matcher_requires_snapshot}}.

-doc """
Return the current ordered rows as an ordinary Erlang list without I/O. Use
list functions or comprehensions for transformations to other value types.
Returns the stored rows without copying their binary fields. Keeping only
the list allows the selection's snapshot context to be collected; other
references can still keep that context alive.
""".
-spec to_list(t(Row)) -> [Row] when Row :: tmux_model:row().
to_list(#selection{rows = Rows}) -> Rows.
-doc """
Fold over current rows in order without I/O, using the function, accumulator,
selection argument order. Arbitrary results are ordinary Erlang values.
""".
-spec fold(fun((Row, Acc) -> Acc), Acc, t(Row)) -> Acc when Row :: tmux_model:row().
fold(Function, Accumulator, #selection{rows = Rows}) -> lists:foldl(Function, Accumulator, Rows).
-doc """
Keep the first N rows and retain the original observation and coverage.
Performs no I/O; taking a subset cannot establish missing field coverage.
""".
-spec take(non_neg_integer(), t(Row)) -> t(Row) when Row :: tmux_model:row().
take(Count, #selection{rows = Rows} = Selection) when is_integer(Count), Count >= 0 ->
    with_rows(lists:sublist(Rows, Count), Selection).
-doc """
Return the cached number of materialized rows in this selection without
traversing tmux or re-evaluating criteria.
""".
-spec size(t()) -> non_neg_integer().
size(#selection{size = Size}) -> Size.

-doc """
Return a compact Erlang diagnostic map with entity, size, capture identity,
interval and coverage. Fetched queries include candidate/attempt information.
Opaque snapshot references make this a diagnostic value, not a wire format.
""".
-spec summary(t()) -> summary().
summary(#selection{entity = Entity, size = Size, context = Context}) ->
    Base = #{entity => Entity, size => Size},
    case Context of
        {snapshot, Snapshot} ->
            Meta = tmux_snapshot:metadata(Snapshot),
            maps:merge(Base#{snapshot_id => maps:get(id, Meta),
                             coverage => maps:get(Entity, tmux_snapshot:coverage(Snapshot))},
                       maps:with([capture_started, capture_finished, time_unit, query], Meta));
        {local, Coverage} ->
            {ok, Relations} = tmux_schema:relations(Entity),
            Base#{snapshot_id => none, coverage => #{collection => complete, fields => Coverage,
                       relations => maps:map(fun(_, _) -> not_loaded end, Relations)}}
    end.

-doc """
Return the first current row or none. Additional matches are allowed. Performs
no I/O.
""".
-spec first(t(Row)) -> {ok, Row} | none when Row :: tmux_model:row().
first(#selection{rows = []}) -> none;
first(#selection{rows = [Row | _]}) -> {ok, Row}.
-doc """
Validate criteria and coverage, then stop at the first local match. Returns
none when no row matches; performs no I/O.
""".
-spec first(criteria(), t(Row)) -> {ok, Row} | none when Row :: tmux_model:row().
first(Criteria, Selection) -> first(matching_prefix(Criteria, Selection, 1)).

-doc """
Return the sole current row or a no_match/multiple_matches error. Ambiguity
reports at_least = 2 rather than computing a needless exact count.
""".
-spec one(t(Row)) -> {ok, Row} | cardinality_error() when Row :: tmux_model:row().
one(#selection{rows = []}) -> {error, no_match};
one(#selection{rows = [Row]}) -> {ok, Row};
one(#selection{rows = [_, _ | _]}) -> {error, {multiple_matches, #{at_least => 2}}}.
-doc """
Validate criteria and coverage, then stop after enough local matches to
establish cardinality. Returns a tagged cardinality result; performs no I/O.
""".
-spec one(criteria(), t(Row)) -> {ok, Row} | cardinality_error() when Row :: tmux_model:row().
one(Criteria, Selection) -> one(matching_prefix(Criteria, Selection, 2)).

-doc """
Return the sole current row, {ok, none} on absence, or a multiple-match error.
Performs no I/O.
""".
-spec one_or_none(t(Row)) -> {ok, Row | none} | cardinality_error() when Row :: tmux_model:row().
one_or_none(Selection) ->
    case one(Selection) of {error, no_match} -> {ok, none}; Result -> Result end.
-doc """
Validate local criteria and return one row or known absence. A second match is
an explicit ambiguity error; performs no I/O.
""".
-spec one_or_none(criteria(), t(Row)) -> {ok, Row | none} | cardinality_error() when Row :: tmux_model:row().
one_or_none(Criteria, Selection) -> one_or_none(matching_prefix(Criteria, Selection, 2)).

-doc """
Return the sole row directly, raising on zero or multiple matches. Use `one/1`
for tagged cardinality errors.
""".
-spec one_or_error(t(Row)) -> Row when Row :: tmux_model:row().
one_or_error(Selection) ->
    case one(Selection) of
        {ok, Row} -> Row;
        {error, Reason} -> erlang:error(Reason, none,
            [{error_info, #{module => tmux_error}}])
    end.
-doc """
Filter locally with complete validation, then return the sole row directly.
Raises on zero or multiple matches; performs no I/O.
""".
-spec one_or_error(criteria(), t(Row)) -> Row when Row :: tmux_model:row().
one_or_error(Criteria, Selection) -> one_or_error(matching_prefix(Criteria, Selection, 2)).

-doc """
Return whether this materialized selection is nonempty, without I/O.
""".
-spec exists(t()) -> boolean().
exists(#selection{size = Size}) -> Size > 0.
-doc """
Validate all criteria/coverage first, then stop at the first local match.
Performs no I/O; an empty selection does not bypass validation.
""".
-spec exists(criteria(), t()) -> boolean().
exists(Criteria, Selection) -> exists(matching_prefix(Criteria, Selection, 1)).
-doc """
Return the current materialized row count without I/O.
""".
-spec count(t()) -> non_neg_integer().
count(Selection) -> size(Selection).
-doc """
Return the exact local match count after full criteria and coverage
validation. Performs no I/O.
""".
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
                _ ->
                    Error = #{code => wrong_row_entity, path => [Index]},
                    erlang:error({bad_selection, Error}, none,
                        [{error_info, #{module => tmux_error}}])
            end;
        {error, Detail} ->
            Error = Detail#{path => [Index | maps:get(path, Detail, [])]},
            erlang:error({bad_selection, Error}, none,
                [{error_info, #{module => tmux_error}}])
    end;
validate_rows(_, _, Index) ->
    erlang:error({bad_selection, #{code => expected_array, path => [Index]}}, none,
        [{error_info, #{module => tmux_error}}]).

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
raise_filter(#{code := incomplete_snapshot} = Detail) ->
    erlang:error({incomplete_snapshot, Detail}, none,
        [{error_info, #{module => tmux_error}}]);
raise_filter(#{code := Code} = Detail) when Code =:= unsupported_regex_subject;
        Code =:= regex_subject_limit; Code =:= regex_resource_limit ->
    erlang:error({filter_evaluation_failed, Detail}, none,
        [{error_info, #{module => tmux_error}}]);
raise_filter(Detail) ->
    erlang:error({bad_filter, Detail}, none,
        [{error_info, #{module => tmux_error}}]).

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
        {error, Detail} -> erlang:error({filter_evaluation_failed, Detail}, none,
            [{error_info, #{module => tmux_error}}])
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
