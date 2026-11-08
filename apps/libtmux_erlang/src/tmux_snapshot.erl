-module(tmux_snapshot).
-moduledoc """
Read an immutable captured graph without performing tmux I/O.

Server-wide lists use numeric ID order. Window links retain every membership,
including multiple indexes for the same window in one session. Session windows
are unique in first-link order; panes within a window use pane index order.
`related/3` accepts a row from this snapshot and returns a
tagged result. A row from another observation cannot silently select a
relationship in this one.

`metadata/1` records source calls, the capture interval,
endpoint generation and the observed server incarnation. Captures span
commands and are not atomic. Values remain readable after their endpoint
closes; actions still validate the row's registered origin. Coverage
distinguishes unloaded data from an empty collection and unavailable fields
from known absence. See the [graph guide](graph.md) for physical windows and
session memberships.
""".
-export([sessions/1, windows/1, window_links/1, panes/1, rows/2, get/3,
         related/3, metadata/1, coverage/1, require/2, build/2]).
-export_type([t/0, requirement/0, metadata/0, source_call/0,
              entity_coverage/0, coverage/0, query_metadata/0]).
-doc """
An immutable captured graph with identity, indexes, coverage and source
intervals.
""".
-opaque t() :: #{rows := map(), indexes := map(), edges := map(),
                 metadata := metadata(), coverage := coverage()}.
-doc """
A collection, field or complete relationship needed for faithful local
evaluation.
""".
-type requirement() :: {collection, tmux_schema:entity()} |
    {field | relation, tmux_schema:entity(), atom()}.
-doc """
One completed capture command and its stdout byte count. started and finished
are local monotonic microseconds, not wall-clock timestamps. The interval
includes identity preflight and command completion; it is not an atomic read.
""".
-type source_call() :: #{command := binary(), args := [binary()],
    started := integer(), finished := integer(), stdout_bytes := non_neg_integer()}.
-doc """
Collection completeness, field availability and relationship completeness. A
loaded field can hold a known value or known absence; inspect the row to
distinguish them. not_loaded never means empty, and unavailable never means
known absence. Completeness is relative to the captured source collection.
""".
-type entity_coverage() :: #{collection := complete | not_loaded,
    fields := #{atom() => loaded | not_loaded | unavailable},
    relations := #{atom() => complete | not_loaded}}.
-doc "Per-entity coverage. Use `require/2` to check requirements before evaluation.".
-type coverage() :: #{tmux_schema:entity() => entity_coverage()}.
-doc """
Source-query capture diagnostics. candidate_count is the deduplicated
candidate identity count before local residuals and limits. pushed_down
records a nontrivial native condition in the plan, not proof that its command
ran: empty collections can skip it. source_calls records actual capture
commands. The flag does not mean the full predicate was translated. attempt
starts at one and increases only for an explicitly requested retry.
""".
-type query_metadata() :: #{candidate_count := non_neg_integer(),
    pushed_down := boolean(), attempt := 1 | 2, consistency := observed}.
-doc """
Capture identity and provenance. id identifies this snapshot, origin its
registered endpoint and generation the endpoint lifetime. model_version names
the row representation. graph describes relationship coverage, not atomicity.

Live captures include endpoint, observed server_instance, tmux_version,
monotonic capture bounds in time_unit, source_calls, observed stdout bytes and
capabilities. Those fields can be absent in internally constructed partial
captures. Query captures also include `t:query_metadata/0`. Opaque references
and process identities are local values, not portable wire identifiers.
""".
-type metadata() :: #{id := reference(), origin := reference(), model_version := 2,
    graph := complete | partial, generation => reference(),
    endpoint => #{socket_path := binary()}, server_instance => tmux_identity:t(),
    tmux_version => tmux_version:t(), capture_started => integer(),
    capture_finished => integer(), time_unit => microsecond,
    source_calls => [source_call()], observed_bytes => non_neg_integer(),
    consistency => observed,
    capabilities => #{field_schema := 1, identity := observed, capture := observed},
    query => query_metadata(), atom() => term()}.

-doc """
Return captured sessions in numeric ID order. Performs no I/O and raises
incomplete_snapshot when that collection was not captured.
""".
-spec sessions(t()) -> [tmux_model:session()].
sessions(Snapshot) -> rows(session, Snapshot).
-doc """
Return unique captured physical windows in numeric ID order. Performs no I/O.
Use `window_links/1` for session-relative membership and indexes.
""".
-spec windows(t()) -> [tmux_model:window()].
windows(Snapshot) -> rows(window, Snapshot).
-doc """
Return every captured membership, ordered by numeric session ID, index and
window ID. Multiple links to the same physical window are preserved. Performs
no I/O; link identity belongs to this snapshot.
""".
-spec window_links(t()) -> [tmux_model:window_link()].
window_links(Snapshot) -> rows(window_link, Snapshot).
-doc """
Return unique captured physical panes in numeric ID order without I/O.
`related/3` orders panes within a window by pane index.
""".
-spec panes(t()) -> [tmux_model:pane()].
panes(Snapshot) -> rows(pane, Snapshot).

-doc """
Return a captured collection by schema entity. Performs no I/O. An unloaded
collection raises incomplete_snapshot rather than appearing empty.
""".
-spec rows(tmux_schema:entity(), t()) -> [tmux_model:row()].
rows(Entity, #{rows := Rows} = Snapshot) ->
    case require([{collection, Entity}], Snapshot) of
        ok -> maps:get(Entity, Rows);
        {error, Detail} -> error({incomplete_snapshot, Detail})
    end.

-doc """
Look up a row in this capture by ID, or a session/index/window tuple for a
window link. Returns none for a known missing identity and a tagged coverage
error for an unloaded collection. Performs no I/O.
""".
-spec get(tmux_schema:entity(), term(), t()) ->
    {ok, tmux_model:row()} | none | {error, map()}.
get(Entity, Key, #{indexes := Indexes} = Snapshot) ->
    maybe
        ok ?= require([{collection, Entity}], Snapshot),
        case maps:find(Key, maps:get(Entity, Indexes)) of
            {ok, Row} -> {ok, Row};
            error -> none
        end
    end.

-doc """
Traverse a complete captured relationship without I/O. To-many relations
return lists; to-one relations return a row or known absence. The input row
must belong to this snapshot. Unloaded relations and mismatched rows return
tagged errors.
""".
-spec related(atom(), tmux_model:row(), t()) ->
    {ok, [tmux_model:row()] | tmux_model:row() | none} | {error, map()}.
related(Relation, Row, #{indexes := Indexes, edges := Edges} = Snapshot) ->
    maybe
        {ok, _} ?= tmux_model:validate(Row),
        Entity = tmux_model:entity(Row),
        ok ?= require([{relation, Entity, Relation}], Snapshot),
        ok ?= case get(Entity, key(Row), Snapshot) of
            {ok, Row} -> ok;
            _ -> {error, #{code => snapshot_row_mismatch}}
        end,
        {ok, Relations} = tmux_schema:relations(Entity),
        #{kind := Kind, target := Target} = maps:get(Relation, Relations),
        Keys = maps:get({Entity, key(Row), Relation}, Edges),
        Values = [maps:get(K, maps:get(Target, Indexes)) || K <- Keys],
        {ok, case {Kind, Values} of
            {many, _} -> Values;
            {one, []} -> none;
            {one, [Value]} -> Value
        end}
    end.

-doc """
Return capture identity, server generation, source calls, capabilities and
read interval metadata. Does not refresh the graph or imply atomic capture.
""".
-spec metadata(t()) -> metadata().
metadata(#{metadata := Metadata}) -> Metadata.
-doc """
Return per-collection, field and relationship coverage. Loaded values, known
absence, not_loaded and unavailable capabilities have distinct meanings.
Performs no I/O.
""".
-spec coverage(t()) -> coverage().
coverage(#{coverage := Coverage}) -> Coverage.

-doc """
Check every declared collection/field/relationship requirement before local
evaluation. Returns an incomplete_snapshot error with missing requirements
when the capture cannot answer faithfully. Performs no I/O, even on empty
data.
""".
-spec require([requirement()], t()) -> ok | {error, map()}.
require(Requirements, #{coverage := Coverage}) when is_list(Requirements) ->
    requirements(Requirements, Coverage, []);
require(_, _) -> {error, #{code => invalid_requirements}}.

%% Internal construction boundary for validated source observations. Partial
%% input never establishes relationship completeness, even when it is empty.
-doc false.
-spec build(map(), map()) -> {ok, t()} | {error, map()}.
build(Input, #{origin := Origin, id := Id, graph := Mode} = Metadata)
  when is_map(Input), is_reference(Origin), is_reference(Id),
       (Mode =:= complete orelse Mode =:= partial) ->
    Entities = tmux_schema_data:entities(),
    maybe
        ok ?= case maps:keys(maps:without(Entities, Input)) of
            [] -> ok;
            _ -> {error, #{code => unknown_entity}}
        end,
        {ok, Indexes} ?= index_entities(Entities, Input, Origin, Id, #{}),
        Rows = maps:map(fun(_, Index) -> sort_rows(maps:values(Index)) end, Indexes),
        ok ?= case Mode of
            complete -> validate_graph(Input, Rows, Indexes);
            partial -> ok
        end,
        Edges = case Mode of complete -> edges(Rows); partial -> #{} end,
        Coverage = maps:from_list([{Entity, entity_coverage(Entity, Input, Rows, Mode)}
                                   || Entity <- Entities]),
        {ok, #{rows => Rows, indexes => Indexes, edges => Edges,
               coverage => Coverage, metadata => Metadata#{model_version => 2}}}
    end;
build(_, _) -> {error, #{code => invalid_snapshot_metadata}}.

index_entities([], _, _, _, Acc) -> {ok, Acc};
index_entities([Entity | Rest], Input, Origin, Id, Acc) ->
    maybe
        {ok, Index} ?= index_rows(maps:get(Entity, Input, []), Entity, Origin, Id, #{}),
        index_entities(Rest, Input, Origin, Id, Acc#{Entity => Index})
    end.

index_rows([], _, _, _, Acc) -> {ok, Acc};
index_rows([Row | Rest], Entity, Origin, Id, Acc) ->
    maybe
        {ok, _} ?= tmux_model:validate(Row),
        ok ?= case {tmux_model:entity(Row), tmux_model:origin(Row)} of
            {Entity, O} when O =:= none; O =:= Origin -> ok;
            _ -> inconsistent(#{reason => wrong_row_context, entity => Entity})
        end,
        Bound = tmux_model:bind(Row, Origin, Id),
        Key = key(Bound),
        ok ?= case maps:find(Key, Acc) of
            error -> ok;
            {ok, Bound} -> ok;
            {ok, Previous} -> inconsistent(#{reason => conflicting_observations,
                entity => Entity, identity => Key,
                fields => [F || {F, V} <- maps:to_list(tmux_model:to_map(Bound)),
                                V =/= tmux_model:get(F, Previous)]})
        end,
        index_rows(Rest, Entity, Origin, Id, Acc#{Key => Bound})
    end;
index_rows(_, Entity, _, _, _) -> {error, #{code => invalid_rows, entity => Entity}}.

key(Row) ->
    case tmux_model:entity(Row) of
        window_link -> {tmux_model:get(session_id, Row), tmux_model:get(index, Row),
                        tmux_model:get(window_id, Row)};
        _ -> tmux_model:get(id, Row)
    end.

sort_rows(Rows) -> lists:sort(fun(A, B) -> order(A) =< order(B) end, Rows).
order(Row) ->
    case key(Row) of
        {Session, Index, Window} -> {number(Session), Index, number(Window)};
        Id -> number(Id)
    end.
number(<<_, Digits/binary>>) -> binary_to_integer(Digits).

validate_graph(Input, Rows, Indexes) ->
    maybe
        ok ?= case lists:all(fun(E) -> maps:is_key(E, Input) end,
                             tmux_schema_data:entities()) of
            true -> ok;
            false -> inconsistent(#{reason => missing_collection})
        end,
        Links = maps:get(window_link, Rows),
        Panes = maps:get(pane, Rows),
        ok ?= references(Links, [{session_id, session}, {window_id, window}], Indexes),
        ok ?= references(Panes, [{window_id, window}], Indexes),
        ok ?= unique_slots(Links, [session_id, index]),
        ok ?= unique_slots(Panes, [window_id, index]),
        counts(maps:get(window, Rows), group(window_id, Panes))
    end.

references([], _, _) -> ok;
references([Row | Rest], Fields, Indexes) ->
    Missing = [F || {F, E} <- Fields,
                    not maps:is_key(tmux_model:get(F, Row), maps:get(E, Indexes))],
    case Missing of
        [] -> references(Rest, Fields, Indexes);
        _ -> inconsistent(#{reason => missing_parent, entity => tmux_model:entity(Row),
                            identity => key(Row), fields => Missing})
    end.

unique_slots(Rows, Fields) ->
    Slots = [[tmux_model:get(F, R) || F <- Fields] || R <- Rows],
    case length(Slots) =:= length(lists:usort(Slots)) of
        true -> ok;
        false -> inconsistent(#{reason => conflicting_positions, fields => Fields})
    end.

counts([], _) -> ok;
counts([Window | Rest], Panes) ->
    Count = length(maps:get(key(Window), Panes, [])),
    case tmux_model:get(pane_count, Window) of
        Count -> counts(Rest, Panes);
        not_loaded -> counts(Rest, Panes);
        unavailable -> counts(Rest, Panes);
        _ -> inconsistent(#{reason => pane_count, identity => key(Window)})
    end.

group(Field, Rows) ->
    Reversed = lists:foldl(fun(Row, Acc) ->
        Key = tmux_model:get(Field, Row),
        Acc#{Key => [Row | maps:get(Key, Acc, [])]}
    end, #{}, Rows),
    maps:map(fun(_, Values) -> lists:reverse(Values) end, Reversed).

edges(Rows) ->
    Links = maps:get(window_link, Rows),
    BySession = group(session_id, Links),
    ByWindow = group(window_id, Links),
    Panes = group(window_id, maps:get(pane, Rows)),
    SessionEdges = lists:append([begin
        Memberships = maps:get(key(S), BySession, []),
        [{{session, key(S), window_links}, [key(L) || L <- Memberships]},
         {{session, key(S), windows}, unique([tmux_model:get(window_id, L) || L <- Memberships])}]
    end || S <- maps:get(session, Rows)]),
    WindowEdges = lists:append([begin
        Children = lists:sort(fun(A, B) ->
            {tmux_model:get(index, A), order(A)} =< {tmux_model:get(index, B), order(B)}
        end, maps:get(key(W), Panes, [])),
        [{{window, key(W), panes}, [key(P) || P <- Children]},
         {{window, key(W), window_links}, [key(L) || L <- maps:get(key(W), ByWindow, [])]}]
    end || W <- maps:get(window, Rows)]),
    LinkEdges = lists:append([[{{window_link, key(L), session}, [tmux_model:get(session_id, L)]},
                              {{window_link, key(L), window}, [tmux_model:get(window_id, L)]}]
                             || L <- Links]),
    PaneEdges = [{{pane, key(P), window}, [tmux_model:get(window_id, P)]}
                 || P <- maps:get(pane, Rows)],
    maps:from_list(SessionEdges ++ WindowEdges ++ LinkEdges ++ PaneEdges).

unique(Values) ->
    {_, Reversed} = lists:foldl(fun(Value, {Seen, Acc}) ->
        case is_map_key(Value, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{Value => true}, [Value | Acc]}
        end
    end, {#{}, []}, Values),
    lists:reverse(Reversed).

entity_coverage(Entity, Input, Rows, Mode) ->
    {ok, Fields} = tmux_schema:fields(Entity),
    {ok, Relations} = tmux_schema:relations(Entity),
    Present = maps:is_key(Entity, Input),
    FieldCoverage = maps:map(fun(Field, _) ->
        Values = [tmux_model:get(Field, Row) || Row <- maps:get(Entity, Rows)],
        Observed = Present andalso (Mode =:= complete orelse Values =/= []),
        case {Observed, lists:member(unavailable, Values), lists:member(not_loaded, Values)} of
            {_, true, _} -> unavailable;
            {false, _, _} -> not_loaded;
            {_, _, true} -> not_loaded;
            _ -> loaded
        end
    end, Fields),
    #{collection => case Present of true -> complete; false -> not_loaded end,
      fields => FieldCoverage,
      relations => maps:map(fun(_, _) ->
          case Mode of complete -> complete; partial -> not_loaded end
      end, Relations)}.

requirements([], _, []) -> ok;
requirements([], _, Missing) ->
    {error, #{code => incomplete_snapshot, requirements => lists:reverse(Missing)}};
requirements([Requirement | Rest], Coverage, Missing) ->
    case requirement(Requirement, Coverage) of
        {ok, loaded} -> requirements(Rest, Coverage, Missing);
        {ok, complete} -> requirements(Rest, Coverage, Missing);
        {ok, State} -> requirements(Rest, Coverage, [#{requirement => Requirement, state => State} | Missing]);
        error -> {error, #{code => invalid_requirement, requirement => Requirement}}
    end.

requirement({collection, Entity}, Coverage) ->
    case maps:find(Entity, Coverage) of
        {ok, Item} -> maps:find(collection, Item);
        error -> error
    end;
requirement({Kind, Entity, Name}, Coverage) when Kind =:= field; Kind =:= relation ->
    case maps:find(Entity, Coverage) of
        {ok, Item} ->
            Key = case Kind of field -> fields; relation -> relations end,
            maps:find(Name, maps:get(Key, Item));
        error -> error
    end;
requirement(_, _) -> error.

inconsistent(Details) -> {error, Details#{code => inconsistent_capture}}.
